import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:shared_preferences/shared_preferences.dart';

/// 局域网里发现的 Mac
class MacHost {
  MacHost(this.name, this.ip, this.port);
  final String name;
  final String ip;
  final int port;
  String get key => '$ip:$port';
  Map<String, dynamic> toJson() => {'name': name, 'ip': ip, 'port': port};
  static MacHost fromJson(Map<String, dynamic> j) => MacHost(j['name'] as String, j['ip'] as String, j['port'] as int);
}

enum Phase { idle, connecting, pairing, online, offline }

class Service {
  Service(this.raw);
  final Map<String, dynamic> raw;
  String get id => raw['id'] as String;
  String get name => raw['name'] as String;
  String get cwd => raw['cwd'] as String? ?? '';
  String get cmd => raw['cmd'] as String? ?? '';
  String get status => raw['status'] as String? ?? 'stopped';
  int? get code => raw['code'] as int?;
  int? get pid => raw['pid'] as int?;
  int? get started => raw['started'] as int?;
  bool get autostart => raw['autostart'] == true;
  bool get blocked => raw['blocked'] == true;
  bool get running => status == 'running' || status == 'stopping';
  List<({String url, int port, bool auto})> get links => [
        for (final l in (raw['links'] as List? ?? []))
          (url: l['url'] as String, port: l['port'] as int, auto: l['auto'] == true)
      ];
}

class WallItem {
  WallItem(this.raw);
  final Map<String, dynamic> raw;
  int get id => raw['id'] as int;
  String get app => raw['app'] as String? ?? '';
  String get title => raw['title'] as String? ?? '';
  String? get note => raw['note'] as String?;
  bool get closed => raw['closed'] == true;
  bool get onScreen => raw['onScreen'] != false;
  int? get changed => raw['changed'] as int?;
  int? get sampled => raw['sampled'] as int?;
  String get label => title.isEmpty ? app : title;
}

class Memo {
  Memo(this.raw);
  final Map<String, dynamic> raw;
  String get id => raw['id'] as String;
  String get text => raw['text'] as String;
  bool get done => raw['done'] != null;
  bool get paused => raw['paused'] != null;
  String get pausedLabel => (raw['paused'] as Map?)?['label'] as String? ?? '';
  bool get closedWindow => (raw['paused'] as Map?)?['closed'] == true;
}

/// 一条日志的缓冲：按行存，末尾未换行的一行（进度条 \r）单独放，整体替换
class LogBuffer {
  final List<String> lines = [];
  String tail = '';
  String _raw = '';
  static final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(\x07|\x1B\\)|\x1B[()][A-Za-z0-9]|\x1B[=>]');

  void clear() {
    lines.clear();
    tail = '';
    _raw = '';
  }

  void append(String chunk) {
    var s = _raw + chunk;
    if (s.contains('\x1B')) s = s.replaceAll(_ansi, '');
    final parts = s.split('\n');
    final last = parts.removeLast();
    for (final l in parts) {
      lines.add(_clean(l));
    }
    _raw = last.length > 20000 ? last.substring(last.length - 20000) : last;
    tail = _clean(last);
    if (lines.length > 6000) lines.removeRange(0, lines.length - 5000);
  }

  String _clean(String l) {
    if (l.endsWith('\r')) l = l.substring(0, l.length - 1);
    final i = l.lastIndexOf('\r');
    return i >= 0 ? l.substring(i + 1) : l;
  }

  int get length => lines.length + (tail.isEmpty ? 0 : 1);
  String operator [](int i) => i < lines.length ? lines[i] : tail;
}

class Conn extends ChangeNotifier {
  Conn() {
    _init();
  }

  // 发现
  final Map<String, MacHost> found = {};
  nsd.Discovery? _discovery;

  // 连接
  Phase phase = Phase.idle;
  MacHost? host;
  String? message; // 连接页上的提示（被拒绝、连不上等）
  WebSocket? _ws;
  Timer? _retry;
  int _attempt = 0;
  bool _paused = false;
  bool _manualOff = false;
  SharedPreferences? _prefs;
  Map<String, String> _tokens = {}; // Mac 名称 -> token
  String _device = 'Android';

  // 数据
  String macName = '';
  List<Service> services = [];
  List<WallItem> wall = [];
  List<Memo> memos = [];
  List<Memo> done = [];
  List<Memo> paused = []; // 从窗口墙暂停下来的监控
  bool screenOK = true;
  bool watch = true;
  int staleAfter = 60;
  int clockOffset = 0; // Mac 时间 - 本机时间（毫秒）
  final Map<int, Uint8List> thumbs = {};
  final toasts = StreamController<String>.broadcast();

  // 订阅
  bool _wallOn = false;
  String? logID;
  final LogBuffer log = LogBuffer();
  int logVersion = 0;

  int get nowSec => (DateTime.now().millisecondsSinceEpoch + clockOffset) ~/ 1000;
  Service? service(String id) => services.where((s) => s.id == id).firstOrNull;

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    final t = _prefs!.getString('tokens');
    if (t != null) _tokens = Map<String, String>.from(jsonDecode(t) as Map);
    try {
      final a = await DeviceInfoPlugin().androidInfo;
      _device = '${a.brand} ${a.model}'.trim();
    } catch (_) {}
    final last = _prefs!.getString('last');
    if (last != null) {
      // 先直接连上次的地址，不等 mDNS
      final h = MacHost.fromJson(jsonDecode(last) as Map<String, dynamic>);
      if (_tokens.containsKey(h.name)) connect(h);
    }
    startDiscovery();
  }

  // MARK: 发现

  Future<void> startDiscovery() async {
    if (_discovery != null) return;
    try {
      final d = await nsd.startDiscovery('_procman._tcp', ipLookupType: nsd.IpLookupType.v4);
      _discovery = d;
      d.addServiceListener((s, status) {
        final ip = s.addresses?.where((a) => a.type == InternetAddressType.IPv4).firstOrNull?.address;
        final name = s.name ?? '';
        if (status == nsd.ServiceStatus.found && ip != null && s.port != null) {
          final h = MacHost(name, ip, s.port!);
          found[name] = h;
          _autoConnect(h);
        } else if (status == nsd.ServiceStatus.lost) {
          found.remove(name);
        }
        notifyListeners();
      });
    } catch (e) {
      message = '局域网发现失败：$e';
      notifyListeners();
    }
  }

  Future<void> stopDiscovery() async {
    final d = _discovery;
    _discovery = null;
    if (d != null) await nsd.stopDiscovery(d);
  }

  /// 发现了已配对过的 Mac 就直接连；从没配对过、局域网里只有这一台就自动发起配对
  void _autoConnect(MacHost h) {
    if (_manualOff) return;
    if (phase == Phase.online || phase == Phase.connecting || phase == Phase.pairing) {
      // 已经连着同名 Mac，但 IP 变了（换网络），下次重连用新地址
      if (host?.name == h.name) host = h;
      return;
    }
    if (_tokens.containsKey(h.name) || (_tokens.isEmpty && found.length == 1)) connect(h);
  }

  // MARK: 连接

  Future<void> connect(MacHost h) async {
    _manualOff = false;
    _retry?.cancel();
    final old = _ws;
    _ws = null;
    await old?.close();
    host = h;
    phase = Phase.connecting;
    message = null;
    notifyListeners();
    try {
      final ws = await WebSocket.connect('ws://${h.ip}:${h.port}/').timeout(const Duration(seconds: 5));
      if (host != h) {
        ws.close();
        return;
      }
      _ws = ws;
      ws.pingInterval = const Duration(seconds: 10);
      ws.listen((m) => _onMessage(ws, m), onDone: () => _onClosed(ws), onError: (_) => _onClosed(ws), cancelOnError: true);
      final token = _tokens[h.name];
      if (token != null) {
        _send({'t': 'hello', 'token': token});
      } else {
        phase = Phase.pairing;
        _send({'t': 'pair', 'device': _device});
        notifyListeners();
      }
    } catch (e) {
      if (host != h) return;
      _fail('连不上 ${h.name}（${h.ip}:${h.port}）');
    }
  }

  void _fail(String msg) {
    message = msg;
    phase = Phase.offline;
    _ws = null;
    notifyListeners();
    _scheduleRetry();
  }

  /// 断线重连：曾经配对过的才重试，退避到最多 10 秒
  void _scheduleRetry() {
    final h = host;
    if (h == null || _paused || _manualOff || !_tokens.containsKey(h.name)) return;
    _retry?.cancel();
    _attempt++;
    _retry = Timer(Duration(seconds: _attempt.clamp(1, 10)), () {
      final latest = found[h.name] ?? h;
      connect(latest);
    });
  }

  void _onClosed(WebSocket ws) {
    if (_ws != ws) return;
    _fail(phase == Phase.online ? '与 Mac 的连接断开，正在重连…' : (message ?? '连接已断开'));
  }

  /// 手动断开，回到选择 Mac 的页面
  Future<void> disconnect() async {
    _manualOff = true;
    _retry?.cancel();
    final ws = _ws;
    _ws = null;
    phase = Phase.idle;
    host = null;
    message = null;
    notifyListeners();
    await ws?.close();
  }

  /// 忘掉这台 Mac 的配对（Mac 那边也会在设置里看到它离线，可以手动移除）
  Future<void> forget(String name) async {
    _tokens.remove(name);
    await _prefs?.setString('tokens', jsonEncode(_tokens));
    if (host?.name == name) await disconnect();
    notifyListeners();
  }

  bool isPaired(String name) => _tokens.containsKey(name);

  /// App 切到后台就断开，回前台再连，省电也省 Mac 截图
  void setPaused(bool p) {
    if (_paused == p) return;
    _paused = p;
    if (p) {
      _retry?.cancel();
      final ws = _ws;
      _ws = null;
      ws?.close();
      if (phase == Phase.online) phase = Phase.offline;
    } else if (host != null && !_manualOff && phase != Phase.online) {
      _attempt = 0;
      connect(found[host!.name] ?? host!);
    }
  }

  void _onMessage(WebSocket ws, dynamic m) {
    if (_ws != ws) return;
    if (m is List<int>) {
      if (m.length < 4) return;
      final b = m is Uint8List ? m : Uint8List.fromList(m);
      final id = ByteData.sublistView(b, 0, 4).getUint32(0);
      thumbs[id] = Uint8List.sublistView(b, 4);
      notifyListeners();
      return;
    }
    final j = jsonDecode(m as String) as Map<String, dynamic>;
    switch (j['t']) {
      case 'paired':
        _tokens[j['host'] as String? ?? host!.name] = j['token'] as String;
        _prefs?.setString('tokens', jsonEncode(_tokens));
      case 'welcome':
        macName = j['host'] as String? ?? host!.name;
        if (!_tokens.containsKey(host!.name) && _tokens.containsKey(macName)) {
          _tokens[host!.name] = _tokens[macName]!;
        }
        phase = Phase.online;
        message = null;
        _attempt = 0;
        _prefs?.setString('last', jsonEncode(host!.toJson()));
        // 重连后恢复订阅
        if (_wallOn) _send({'t': 'wall', 'on': true});
        if (logID != null) _send({'t': 'log', 'id': logID});
        notifyListeners();
      case 'denied':
        message = j['reason'] as String? ?? 'Mac 拒绝了连接';
        _manualOff = true;
        phase = Phase.offline;
        _ws = null;
        ws.close();
        notifyListeners();
      case 'unauthorized':
        // token 被 Mac 移除了，重新配对
        if (host != null && _tokens.remove(host!.name) != null) {
          _prefs?.setString('tokens', jsonEncode(_tokens));
          phase = Phase.pairing;
          _send({'t': 'pair', 'device': _device});
          notifyListeners();
        }
      case 'state':
        clockOffset = (j['ts'] as int) - DateTime.now().millisecondsSinceEpoch;
        macName = j['host'] as String? ?? macName;
        services = [for (final s in j['services'] as List) Service(s as Map<String, dynamic>)];
        wall = [for (final w in j['wall'] as List) WallItem(w as Map<String, dynamic>)];
        memos = [for (final x in j['memos'] as List) Memo(x as Map<String, dynamic>)];
        done = [for (final x in j['done'] as List) Memo(x as Map<String, dynamic>)];
        paused = [for (final x in (j['paused'] as List? ?? [])) Memo(x as Map<String, dynamic>)];
        screenOK = j['screenOK'] != false;
        watch = j['watch'] != false;
        staleAfter = j['staleAfter'] as int? ?? 60;
        final ids = wall.map((w) => w.id).toSet();
        thumbs.removeWhere((k, _) => !ids.contains(k));
        notifyListeners();
      case 'log':
        if (j['id'] != logID) return;
        if (j['reset'] == true) log.clear();
        log.append(j['data'] as String? ?? '');
        logVersion++;
        notifyListeners();
      case 'toast':
        toasts.add(j['text'] as String);
    }
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  // MARK: 操作

  void start(String id) => _send({'t': 'start', 'id': id});
  void stop(String id) => _send({'t': 'stop', 'id': id});
  void restart(String id) => _send({'t': 'restart', 'id': id});
  void focus(int win) => _send({'t': 'focus', 'win': win});
  void addMemo(String text) => _send({'t': 'memo.add', 'text': text});
  void toggleMemo(String id) => _send({'t': 'memo.toggle', 'id': id});
  void editMemo(String id, String text) => _send({'t': 'memo.edit', 'id': id, 'text': text});
  void deleteMemo(String id) => _send({'t': 'memo.delete', 'id': id});
  void resumeMemo(String id) => _send({'t': 'memo.resume', 'id': id});
  void pauseWindow(int win) => _send({'t': 'wall.pause', 'win': win});

  void watchWall(bool on) {
    if (_wallOn == on) return;
    _wallOn = on;
    _send({'t': 'wall', 'on': on});
  }

  void watchLog(String? id) {
    logID = id;
    log.clear();
    logVersion++;
    _send({'t': 'log', 'id': id ?? ''});
  }

  /// 服务链接里的 127.0.0.1 / localhost 换成 Mac 的局域网地址，手机上才打得开
  String reachable(String url) =>
      host == null ? url : url.replaceFirst(RegExp(r'//(127\.0\.0\.1|localhost|0\.0\.0\.0)'), '//${host!.ip}');
}
