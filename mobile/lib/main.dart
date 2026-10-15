import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'conn.dart';

final conn = Conn();

const accent = Color(0xFF66E699);
const bg = Color(0xFF12141C);
const surface = Color(0xFF1B1E29);
const logBg = Color(0xFF13141A);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProcmanApp());
}

class ProcmanApp extends StatelessWidget {
  const ProcmanApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark, surface: bg);
    return MaterialApp(
      title: 'Procman',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: bg,
        cardTheme: const CardThemeData(color: surface, margin: EdgeInsets.zero),
        appBarTheme: const AppBarTheme(backgroundColor: bg, scrolledUnderElevation: 0),
      ),
      home: const Root(),
    );
  }
}

/// 没连上显示选择 Mac 的页面，连上了显示主界面
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  StreamSubscription<String>? _toasts;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _toasts = conn.toasts.stream.listen((t) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _toasts?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) conn.setPaused(false);
    if (s == AppLifecycleState.paused) conn.setPaused(true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: conn,
      builder: (context, _) {
        // 连上过一次就留在主界面，断线时顶部显示重连条，不来回跳页
        final h = conn.host;
        final inMain = conn.phase == Phase.online ||
            (h != null && conn.macName.isNotEmpty && conn.isPaired(h.name) && conn.phase != Phase.idle && conn.phase != Phase.pairing);
        return inMain ? HomePage() : ConnectPage(); // 不加 const，conn 变化时跟着重建
      },
    );
  }
}

// MARK: - 连接页

class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key});

  @override
  Widget build(BuildContext context) {
    final hosts = conn.found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    final busy = conn.phase == Phase.connecting || conn.phase == Phase.pairing;
    return Scaffold(
      appBar: AppBar(title: const Text('Procman')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Icon(Icons.inventory_2, color: accent, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                busy
                    ? (conn.phase == Phase.pairing ? '请在 Mac 上点「允许」…' : '正在连接 ${conn.host?.name ?? ''}…')
                    : '正在局域网里查找 Procman…',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (busy || hosts.isEmpty) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          if (conn.message != null) ...[
            const SizedBox(height: 12),
            Text(conn.message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          for (final h in hosts) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.laptop_mac),
                title: Text(h.name),
                subtitle: Text('${h.ip}:${h.port}${conn.isPaired(h.name) ? ' · 已配对' : ''}'),
                trailing: conn.isPaired(h.name)
                    ? IconButton(
                        tooltip: '忘记配对',
                        icon: const Icon(Icons.link_off),
                        onPressed: () => conn.forget(h.name),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: busy ? null : () => conn.connect(h),
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 12),
          TextButton.icon(
            icon: const Icon(Icons.edit),
            label: const Text('手动输入地址'),
            onPressed: () => _manual(context),
          ),
          const SizedBox(height: 8),
          Text(
            '手机和 Mac 需要在同一个局域网。Mac 上打开 Procman → 设置 → 手机远程 可以看到地址；第一次连接要在 Mac 上确认。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Future<void> _manual(BuildContext context) async {
    final c = TextEditingController(text: conn.host == null ? '' : '${conn.host!.ip}:${conn.host!.port}');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mac 地址'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: '192.168.1.10:7788'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('连接')),
        ],
      ),
    );
    if (v == null || v.trim().isEmpty) return;
    final parts = v.trim().split(':');
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 7788 : 7788;
    // 名称先用地址，登录后以 Mac 返回的名称保存 token
    final known = conn.found.values.where((h) => h.ip == parts[0]).firstOrNull;
    conn.connect(MacHost(known?.name ?? parts[0], parts[0], port));
  }
}

// MARK: - 主界面

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    conn.watchWall(tab == 0);
  }

  @override
  void dispose() {
    conn.watchWall(false);
    super.dispose();
  }

  void _select(int i) {
    setState(() => tab = i);
    conn.watchWall(i == 0);
  }

  @override
  Widget build(BuildContext context) {
    final running = conn.services.where((s) => s.running).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(conn.macName, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'disconnect') conn.disconnect();
              if (v == 'forget' && conn.host != null) conn.forget(conn.host!.name);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'disconnect', child: Text('断开 / 切换 Mac')),
              PopupMenuItem(value: 'forget', child: Text('忘记这台 Mac')),
            ],
          ),
        ],
        bottom: conn.phase == Phase.online
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Container(
                  height: 28,
                  color: Colors.orange.withValues(alpha: 0.2),
                  alignment: Alignment.center,
                  child: Text(conn.message ?? '正在重连…', style: const TextStyle(fontSize: 12, color: Colors.orange)),
                ),
              ),
      ),
      body: IndexedStack(index: tab, children: [WallPage(), ServicesPage(), MemosPage()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: _select,
        destinations: [
          const NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view), label: '窗口墙'),
          NavigationDestination(
            icon: Badge(isLabelVisible: running > 0, label: Text('$running'), child: const Icon(Icons.inventory_2_outlined)),
            selectedIcon: const Icon(Icons.inventory_2),
            label: '服务',
          ),
          NavigationDestination(
            icon: Badge(isLabelVisible: conn.memos.isNotEmpty, label: Text('${conn.memos.length}'), child: const Icon(Icons.checklist)),
            label: '待办',
          ),
        ],
      ),
    );
  }
}

/// 每秒重建一次（运行时长、静止时长）
class Ticker extends StatefulWidget {
  const Ticker({super.key, required this.builder, this.seconds = 1});
  final WidgetBuilder builder;
  final int seconds;
  @override
  State<Ticker> createState() => _TickerState();
}

class _TickerState extends State<Ticker> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(Duration(seconds: widget.seconds), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

String duration(int s) {
  if (s < 60) return '$s 秒';
  if (s < 3600) return '${s ~/ 60} 分钟';
  if (s < 86400) return '${s ~/ 3600} 小时${s % 3600 ~/ 60 > 0 ? ' ${s % 3600 ~/ 60} 分' : ''}';
  return '${s ~/ 86400} 天';
}

String uptime(int s) {
  s = s < 0 ? 0 : s;
  final d = s ~/ 86400, h = s % 86400 ~/ 3600, m = s % 3600 ~/ 60;
  if (d > 0) return '$d 天 $h 小时';
  if (h > 0) return '$h 小时 $m 分';
  if (m > 0) return '$m 分 ${s % 60} 秒';
  return '$s 秒';
}

// MARK: - 窗口墙

class WallPage extends StatelessWidget {
  const WallPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = conn.wall;
    if (items.isEmpty) {
      return const _Empty(icon: Icons.grid_view, title: '还没有监控的窗口', text: '在 Mac 上用快捷键或「管理监控」把窗口加到窗口墙');
    }
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 1000 ? 3 : box.maxWidth >= 600 ? 2 : 1;
      return CustomScrollView(slivers: [
        if (!conn.screenOK)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text('Mac 上 Procman 没有「屏幕录制」权限，无法显示缩略图', style: TextStyle(color: Colors.orange)),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.25,
            ),
            itemCount: items.length,
            itemBuilder: (_, i) => WallTile(item: items[i]),
          ),
        ),
      ]);
    });
  }
}

class WallTile extends StatelessWidget {
  const WallTile({super.key, required this.item});
  final WallItem item;

  @override
  Widget build(BuildContext context) {
    final img = conn.thumbs[item.id];
    final note = item.note;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: item.closed
            ? null
            : () {
                conn.focus(item.id);
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text('已在 Mac 上切到「${item.label}」'), duration: const Duration(seconds: 1)));
              },
        onLongPress: () => _menu(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Container(
              color: Colors.black26,
              child: img != null
                  ? Image.memory(img, fit: BoxFit.contain, gaplessPlayback: true)
                  : Center(
                      child: Icon(item.closed ? Icons.check_circle_outline : Icons.web_asset, size: 40, color: Colors.white24),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(item.app, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (item.closed)
                  const _Badge('窗口已关闭')
                else if (!item.onScreen)
                  const _Badge('其他桌面')
                else
                  StillBadge(item: item),
              ]),
              if (item.title.isNotEmpty)
                Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white60)),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('📝 $note', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xFFFFD27A))),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  void _menu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(item.app)),
          if (conn.thumbs[item.id] != null)
            ListTile(
              leading: const Icon(Icons.zoom_in),
              title: const Text('查看大图'),
              onTap: () {
                Navigator.pop(ctx);
                _zoom(context);
              },
            ),
          ListTile(
            leading: const Icon(Icons.pause_circle_outline),
            title: Text(item.wholeApp ? '暂停监控整个 ${item.app}（转为待办）' : '暂停监控（转为待办）'),
            subtitle: const Text('之后在「待办 → 已暂停」里恢复'),
            onTap: () {
              Navigator.pop(ctx);
              conn.pauseWindow(item.id);
            },
          ),
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined, color: Colors.redAccent),
            title: Text(item.wholeApp ? '取消监控整个 ${item.app}' : '取消监控'),
            subtitle: item.note == null ? null : const Text('备注会一起删除'),
            onTap: () async {
              Navigator.pop(ctx);
              if (await _confirmUnmark(context)) conn.unmarkWindow(item.id);
            },
          ),
        ]),
      ),
    );
  }

  Future<bool> _confirmUnmark(BuildContext context) async {
    if (item.note == null) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.wholeApp ? '取消监控整个 ${item.app}？' : '取消监控「${item.label}」？'),
        content: Text('备注「${item.note}」会一起删除。只是暂时不想看的话可以用「暂停监控」。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('保留')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('取消监控'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _zoom(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, title: Text(item.label)),
        body: ListenableBuilder(
          listenable: conn,
          builder: (_, _) {
            final img = conn.thumbs[item.id];
            return InteractiveViewer(
              maxScale: 5,
              child: Center(child: img == null ? const SizedBox() : Image.memory(img, gaplessPlayback: true)),
            );
          },
        ),
      ),
    ));
  }
}

/// 和 Mac 窗口墙一样：30 秒内有变化算「活动中」，否则显示静止多久
class StillBadge extends StatelessWidget {
  const StillBadge({super.key, required this.item});
  final WallItem item;

  @override
  Widget build(BuildContext context) {
    return Ticker(
      seconds: 5,
      builder: (_) {
        if (!conn.watch && item.sampled == null) return const SizedBox();
        final now = conn.nowSec;
        final c = item.changed, s = item.sampled;
        if (c != null && s != null && now - s < conn.staleAfter) {
          final t = now - c;
          if (t < 30) {
            return const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.circle, size: 8, color: Colors.green),
              SizedBox(width: 4),
              Text('活动中', style: TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.w500)),
            ]);
          }
          return _Badge('静止 ${duration(t)}');
        }
        if (s != null || conn.screenOK) return const _Badge('无法采样');
        return const SizedBox();
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(fontSize: 11, color: Colors.white60, fontWeight: FontWeight.w500)),
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54)),
          ]),
        ),
      );
}

// MARK: - 服务

Color statusColor(Service s) => switch (s.status) {
      'running' => Colors.green,
      'stopping' => Colors.orange,
      'crashed' => Colors.redAccent,
      _ => Colors.white24,
    };

class StatusDot extends StatelessWidget {
  const StatusDot(this.s, {super.key});
  final Service s;
  @override
  Widget build(BuildContext context) {
    final c = statusColor(s);
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: s.status == 'running' ? BoxDecoration(shape: BoxShape.circle, color: c.withValues(alpha: 0.3)) : null,
      child: Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
    );
  }
}

class ServicesPage extends StatelessWidget {
  const ServicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final list = conn.services;
    if (list.isEmpty) return const _Empty(icon: Icons.inventory_2, title: '还没有服务', text: '在 Mac 上的 Procman 里新建服务');
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: list.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Text('服务 · ${list.where((s) => s.running).length}/${list.length} 运行中', style: const TextStyle(color: Colors.white54, fontSize: 13)),
          );
        }
        final s = list[i - 1];
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.only(left: 14, right: 6),
            leading: StatusDot(s),
            minLeadingWidth: 14,
            title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
            subtitle: Text(subtitle(s), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (s.blocked) const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
              _ToggleButton(s),
            ]),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(id: s.id))),
          ),
        );
      },
    );
  }

  static String subtitle(Service s) {
    final links = s.links;
    final where = links.isNotEmpty ? ':${links.first.port}' : s.cwd.split('/').last;
    return switch (s.status) {
      'running' => '运行中 · $where',
      'stopping' => '停止中…',
      'crashed' => '异常退出 (${s.code}) · $where',
      'exited' => '已退出 · $where',
      _ => where,
    };
  }
}

class _ToggleButton extends StatelessWidget {
  const _ToggleButton(this.s);
  final Service s;
  @override
  Widget build(BuildContext context) {
    if (s.status == 'stopping') {
      return const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    return s.running
        ? IconButton(
            tooltip: '停止',
            icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
            onPressed: () => _confirmStop(context, s),
          )
        : IconButton(tooltip: '启动', icon: const Icon(Icons.play_circle_outline, color: accent), onPressed: () => conn.start(s.id));
  }
}

Future<void> _confirmStop(BuildContext context, Service s) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('停止「${s.name}」？'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('停止'),
        ),
      ],
    ),
  );
  if (ok == true) conn.stop(s.id);
}

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.id});
  final String id;
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  final _scroll = ScrollController();
  bool follow = true;
  bool showCmd = false;

  @override
  void initState() {
    super.initState();
    conn.watchLog(widget.id);
    conn.addListener(_onChange);
    _scroll.addListener(() {
      // 手动往上翻就暂停自动滚动，翻回底部恢复
      if (!_scroll.hasClients) return;
      final atEnd = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24;
      if (atEnd != follow) setState(() => follow = atEnd);
    });
  }

  int _seen = -1;
  void _onChange() {
    if (conn.logVersion != _seen) {
      _seen = conn.logVersion;
      if (follow) WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
    }
  }

  void _toEnd() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  void dispose() {
    conn.removeListener(_onChange);
    conn.watchLog(null);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: conn,
      builder: (context, _) {
        final s = conn.service(widget.id);
        if (s == null) return Scaffold(appBar: AppBar(), body: const _Empty(icon: Icons.delete_outline, title: '服务已删除', text: ''));
        return Scaffold(
          appBar: AppBar(title: Text(s.name)),
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _header(s),
            const Divider(height: 1),
            Container(
              color: surface,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(children: [
                const Icon(Icons.notes, size: 16),
                const SizedBox(width: 6),
                const Text('输出', style: TextStyle(fontWeight: FontWeight.w500)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    setState(() => follow = !follow);
                    if (follow) _toEnd();
                  },
                  icon: Icon(follow ? Icons.vertical_align_bottom : Icons.pause, size: 16),
                  label: Text(follow ? '自动滚动' : '已暂停'),
                ),
              ]),
            ),
            Expanded(child: _logView()),
          ]),
        );
      },
    );
  }

  Widget _header(Service s) {
    final busy = s.status == 'stopping';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          StatusDot(s),
          const SizedBox(width: 6),
          Expanded(
            child: Ticker(
              builder: (_) => Text(_statusText(s), style: const TextStyle(color: Colors.white70, fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final l in s.links)
            ActionChip(
              avatar: Icon(s.running ? Icons.sensors : Icons.link, size: 16, color: s.running ? Colors.green : accent),
              label: Text('${conn.reachable(l.url)}${l.auto ? ' · 自动' : ''}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              onPressed: () => launchUrl(Uri.parse(conn.reachable(l.url)), mode: LaunchMode.externalApplication),
            ),
          Chip(
            avatar: const Icon(Icons.folder_outlined, size: 16),
            label: Text(s.cwd, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ]),
        if (s.blocked)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('端口 ${s.links.firstOrNull?.port ?? ''} 被其他进程占用', style: const TextStyle(color: Colors.orange)),
          ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => setState(() => showCmd = !showCmd),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: s.cmd));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制命令')));
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8)),
            child: Text(
              s.cmd,
              maxLines: showCmd ? 20 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: Colors.white70),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          if (s.running) ...[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => conn.restart(s.id),
                icon: const Icon(Icons.refresh),
                label: const Text('重启'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                onPressed: busy ? null : () => _confirmStop(context, s),
                icon: const Icon(Icons.stop),
                label: Text(busy ? '停止中…' : '停止'),
              ),
            ),
          ] else
            Expanded(
              child: FilledButton.icon(onPressed: () => conn.start(s.id), icon: const Icon(Icons.play_arrow), label: const Text('启动')),
            ),
        ]),
      ]),
    );
  }

  String _statusText(Service s) => switch (s.status) {
        'running' => '运行中 · PID ${s.pid} · 已运行 ${uptime(conn.nowSec - (s.started ?? conn.nowSec))}',
        'stopping' => '正在停止…',
        'crashed' => '异常退出，退出码 ${s.code}',
        'exited' => s.code == null ? '已退出' : '已退出，退出码 ${s.code}',
        _ => '未运行',
      };

  Widget _logView() {
    final log = conn.log;
    return Container(
      color: logBg,
      child: SelectionArea(
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
          itemCount: log.length,
          itemBuilder: (_, i) {
            final l = log[i];
            return Text(l, style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35, color: _lineColor(l)));
          },
        ),
      ),
    );
  }

  static Color _lineColor(String l) {
    if (l.startsWith('=====')) return const Color(0xFF73ADFF);
    if (l.startsWith(r'$ ')) return Colors.white54;
    final low = (l.length > 400 ? l.substring(0, 400) : l).toLowerCase();
    if (low.contains('error') || low.contains('traceback') || low.contains('exception') || low.contains('failed')) {
      return const Color(0xFFFF736B);
    }
    if (low.contains('warn')) return const Color(0xFFFFBF59);
    return const Color(0xFFDBDBDB);
  }
}

// MARK: - 待办

class MemosPage extends StatefulWidget {
  const MemosPage({super.key});
  @override
  State<MemosPage> createState() => _MemosPageState();
}

class _MemosPageState extends State<MemosPage> {
  final _input = TextEditingController();
  bool showDone = false;

  void _add() {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    conn.addMemo(t);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _input,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _add(),
          decoration: InputDecoration(
            hintText: '记一件事…',
            filled: true,
            fillColor: surface,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: _add),
          ),
        ),
        const SizedBox(height: 8),
        for (final m in conn.memos) _row(m),
        if (conn.memos.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('没有待办 🎉', style: TextStyle(color: Colors.white54)))),
        if (conn.paused.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 4, 4),
            child: Row(children: [
              Icon(Icons.pause_circle_outline, size: 16, color: Colors.white54),
              SizedBox(width: 6),
              Text('已暂停的窗口', style: TextStyle(color: Colors.white54, fontSize: 13)),
            ]),
          ),
          for (final m in conn.paused) _row(m),
        ],
        if (conn.done.isNotEmpty) ...[
          TextButton.icon(
            onPressed: () => setState(() => showDone = !showDone),
            icon: Icon(showDone ? Icons.expand_less : Icons.expand_more),
            label: Text('已完成 ${conn.done.length}'),
          ),
          if (showDone) for (final m in conn.done) _row(m),
        ],
      ],
    );
  }

  Widget _row(Memo m) => Dismissible(
        key: ValueKey(m.id),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: Colors.redAccent.withValues(alpha: 0.6),
          child: const Icon(Icons.delete),
        ),
        onDismissed: (_) => conn.deleteMemo(m.id),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Checkbox(value: m.done, onChanged: (_) => conn.toggleMemo(m.id)),
          title: Text(
            m.text,
            style: m.done ? const TextStyle(color: Colors.white38, decoration: TextDecoration.lineThrough) : null,
          ),
          subtitle: m.paused && !m.done
              ? Text(
                  [if (m.text != m.pausedLabel) m.pausedLabel, m.closedWindow ? '窗口已关闭，重开后自动恢复' : '已暂停'].join(' · '),
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                )
              : null,
          trailing: m.paused && !m.done
              ? IconButton(
                  tooltip: '恢复监控',
                  icon: const Icon(Icons.play_circle_outline, color: accent),
                  onPressed: () => conn.resumeMemo(m.id),
                )
              : null,
          onTap: () => _edit(m),
        ),
      );

  Future<void> _edit(Memo m) async {
    final c = TextEditingController(text: m.text);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑待办'),
        content: TextField(controller: c, autofocus: true, maxLines: null),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('保存')),
        ],
      ),
    );
    if (v != null && v.trim() != m.text) conn.editMemo(m.id, v); // 改成空 = 删除
  }
}
