import AppKit
import Network
import Observation

// MARK: - 手机远程：局域网 WebSocket + Bonjour 广播
//
// 协议（文本帧都是 JSON，字段 t 表示类型）：
//   手机 → Mac  未认证：pair{device} 申请配对（Mac 弹窗确认），hello{token} 用已配对的 token 登录
//              已认证：start/stop/restart{id}、log{id}（空 id = 取消订阅）、wall{on}、focus{win}、
//                     memo.add{text}、memo.toggle{id}、memo.edit{id,text}、memo.delete{id}、
//                     memo.resume{id} 恢复暂停的窗口监控、wall.pause{win} 暂停监控转为待办
//   Mac → 手机  paired{token,host}、denied{reason}、unauthorized、welcome{host}、
//              state{ts,services,wall,memos,...}（有变化才发）、log{id,reset,data}、toast{text}
//   二进制帧    窗口墙缩略图：4 字节大端窗口 id + JPEG

struct Paired: Codable, Hashable, Identifiable {
    var name: String
    var token: String
    var added = Date()
    var seen: Date?
    var id: String { token }
}

@MainActor
private final class Client {
    let conn: NWConnection
    var token: String?
    var name = ""
    var lastState: Data?
    var logID: String?
    var logOffset: UInt64?
    var logCarry = Data()
    var wall = false
    var sentThumbs: [CGWindowID: NSImage] = [:]
    var pending = 0   // 还没发出去的帧，缩略图积压时先跳过
    init(_ conn: NWConnection) { self.conn = conn }
}

@MainActor @Observable
final class Remote {
    static let shared = Remote()
    static let defaultPort: UInt16 = 7788
    static let serviceType = "_procman._tcp"

    private(set) var devices: [Paired] = []
    private(set) var enabled = UserDefaults.standard.object(forKey: "remoteOn") as? Bool ?? true
    private(set) var port: UInt16?          // 正在监听的端口
    private(set) var error: String?
    private(set) var online: [String: Int] = [:]   // token -> 连接数

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [ObjectIdentifier: Client] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pairing = false
    @ObservationIgnored private var jpegs: [CGWindowID: (NSImage, Data)] = [:]
    @ObservationIgnored let hostName = Host.current().localizedName ?? "Mac"

    private var url: URL { Store.shared.home.appendingPathComponent("remote.json") }
    private static let decoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private init() {
        if let d = try? Data(contentsOf: url), let p = try? Self.decoder.decode([Paired].self, from: d) { devices = p }
    }

    // MARK: 开关

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "remoteOn")
        on ? start() : stop()
    }

    func start() {
        guard enabled, listener == nil else { return }
        listen(on: Self.defaultPort)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        for c in clients.values { c.conn.cancel() }
        clients.removeAll()
        online.removeAll()
        Wall.shared.remoteViewers = 0
        updateTimer()
    }

    /// 固定端口被占用时退回随机端口（Bonjour 广播的是实际端口，手机照样能发现）
    private func listen(on fixed: UInt16?) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try fixed.flatMap(NWEndpoint.Port.init(rawValue:)).map { try NWListener(using: params, on: $0) }
                ?? NWListener(using: params)
        } catch {
            self.error = "无法监听：\(error.localizedDescription)"
            return
        }
        l.service = NWListener.Service(name: hostName, type: Self.serviceType)
        l.stateUpdateHandler = { [weak l] st in
            MainActor.assumeIsolated {
                let r = Remote.shared
                guard let l, r.listener === l else { return }
                switch st {
                case .ready:
                    r.port = l.port?.rawValue
                    r.error = nil
                case .failed(let e):
                    l.cancel()
                    r.listener = nil
                    r.port = nil
                    if fixed != nil { r.listen(on: nil) } else { r.error = "监听失败：\(e.localizedDescription)" }
                default: break
                }
            }
        }
        l.newConnectionHandler = { conn in MainActor.assumeIsolated { Remote.shared.accept(conn) } }
        listener = l
        l.start(queue: .main)
    }

    func unpair(_ token: String) {
        devices.removeAll { $0.token == token }
        save()
        for c in clients.values where c.token == token { c.conn.cancel() }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(devices).write(to: url, options: .atomic)
    }

    // MARK: 连接

    private func accept(_ conn: NWConnection) {
        let c = Client(conn)
        clients[ObjectIdentifier(c)] = c
        conn.stateUpdateHandler = { [weak c] st in
            MainActor.assumeIsolated {
                guard let c else { return }
                switch st {
                case .failed, .cancelled: Remote.shared.drop(c)
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receive(c)
        // 10 秒内不登录也不申请配对就断开
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak c] in
            MainActor.assumeIsolated {
                if let c, c.token == nil, !Remote.shared.pairing { c.conn.cancel() }
            }
        }
        updateTimer()
    }

    private func drop(_ c: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        if c.wall { Wall.shared.remoteViewers -= 1 }
        if let t = c.token {
            online[t] = (online[t] ?? 1) - 1
            if online[t] == 0 { online[t] = nil }
        }
        c.conn.cancel()
        updateTimer()
    }

    private func receive(_ c: Client) {
        c.conn.receiveMessage { [weak c] data, ctx, _, err in
            MainActor.assumeIsolated {
                guard let c else { return }
                let r = Remote.shared
                let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if err != nil || meta?.opcode == .close { r.drop(c); return }
                if let data, !data.isEmpty, meta?.opcode != .binary { r.handle(c, data) }
                if r.clients[ObjectIdentifier(c)] != nil { r.receive(c) }
            }
        }
    }

    private func peer(_ c: Client) -> String {
        if case let .hostPort(host, _) = c.conn.endpoint { return "\(host)".components(separatedBy: "%").first ?? "\(host)" }
        return "\(c.conn.endpoint)"
    }

    // MARK: 消息处理

    private func handle(_ c: Client, _ data: Data) {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let t = m["t"] as? String else { return }
        guard c.token != nil else {
            switch t {
            case "hello":
                if let tok = m["token"] as? String, let i = devices.firstIndex(where: { $0.token == tok }) {
                    devices[i].seen = Date()
                    save()
                    login(c, devices[i])
                } else {
                    send(c, ["t": "unauthorized"])
                }
            case "pair":
                ask(c, String((m["device"] as? String ?? "未知设备").prefix(60)))
            default:
                send(c, ["t": "unauthorized"])
            }
            return
        }

        let st = Store.shared
        let id = m["id"] as? String ?? ""
        switch t {
        case "start":
            guard st.runs[id] == nil else { break }
            do { try st.start(id) } catch { send(c, ["t": "toast", "text": error.localizedDescription]) }
        case "stop": st.stop(id)
        case "restart": st.restart(id)
        case "log":
            c.logID = st.service(id) == nil ? nil : id
            c.logOffset = nil
            c.logCarry = Data()
            pumpLog(c)
        case "wall":
            let on = m["on"] as? Bool ?? false
            if on != c.wall { Wall.shared.remoteViewers += on ? 1 : -1 }
            c.wall = on
            if on { c.sentThumbs.removeAll() }
        case "focus":
            if let win = m["win"] as? Int, let w = Wall.shared.windows.first(where: { Int($0.id) == win }) {
                if let msg = focusWindow(w) { send(c, ["t": "toast", "text": msg]) }
            }
        case "memo.add": Memos.shared.add(m["text"] as? String ?? "")
        case "memo.toggle": Memos.shared.toggle(id)
        case "memo.edit": Memos.shared.edit(id, m["text"] as? String ?? "")
        case "memo.delete": Memos.shared.delete(id)
        case "memo.resume": Memos.shared.resume(id)
        case "wall.pause":
            if let win = m["win"] as? Int, let item = Wall.shared.items.first(where: { Int($0.id) == win }) {
                Wall.shared.pause(item)
            }
        default: break
        }
        // 操作后尽快把新状态推回去，不等下一拍
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { Remote.shared.tick() } }
    }

    private func login(_ c: Client, _ d: Paired) {
        c.token = d.token
        c.name = d.name
        online[d.token, default: 0] += 1
        send(c, ["t": "welcome", "host": hostName])
        tick()
    }

    private func ask(_ c: Client, _ device: String) {
        guard !pairing else { send(c, ["t": "denied", "reason": "Mac 上已有一个配对请求等待确认"]); return }
        pairing = true
        let from = peer(c)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "允许「\(device)」连接 Procman？"
            a.informativeText = "来自 \(from)。\n允许后这台设备可以查看服务、日志、窗口墙和待办，并启动 / 停止服务（不能修改命令）。之后可以在 设置 → 手机远程 里移除。"
            a.addButton(withTitle: "允许")
            a.addButton(withTitle: "拒绝")
            let ok = a.runModal() == .alertFirstButtonReturn
            MainActor.assumeIsolated {
                let r = Remote.shared
                r.pairing = false
                guard r.clients[ObjectIdentifier(c)] != nil else { return }
                guard ok else { r.send(c, ["t": "denied", "reason": "Mac 上拒绝了连接"]); return }
                let d = Paired(name: device, token: UUID().uuidString + UUID().uuidString, seen: Date())
                r.devices.append(d)
                r.save()
                r.send(c, ["t": "paired", "token": d.token, "host": r.hostName])
                r.login(c, d)
            }
        }
    }

    // MARK: 推送

    private func updateTimer() {
        if clients.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { Remote.shared.tick() }
            }
        }
    }

    private func tick() {
        let authed = clients.values.filter { $0.token != nil }
        guard !authed.isEmpty else { return }
        var st = state()
        guard let key = try? JSONSerialization.data(withJSONObject: st, options: .sortedKeys) else { return }
        st["t"] = "state"
        st["ts"] = Int(Date().timeIntervalSince1970 * 1000)
        let full = try? JSONSerialization.data(withJSONObject: st)
        let wanted: Set<CGWindowID> = authed.contains(where: \.wall) ? Set(Wall.shared.thumbs.keys) : []
        jpegs = jpegs.filter { wanted.contains($0.key) }
        for c in authed {
            if c.lastState != key, let full {
                c.lastState = key
                sendData(c, full, .text)
            }
            pumpLog(c)
            if c.wall { pushThumbs(c) }
        }
    }

    private func state() -> [String: Any] {
        let st = Store.shared, wall = Wall.shared
        let services: [[String: Any]] = st.services.map { s in
            var d: [String: Any] = [
                "id": s.id, "name": s.name, "cwd": abbreviate(s.dir), "cmd": s.cmd,
                "autostart": s.autostart, "restart": s.restart, "blocked": st.portBlocked(s.id),
                "links": st.links(s.id).map { ["url": $0.url, "port": $0.port, "auto": $0.auto] as [String: Any] },
            ]
            switch st.status(s.id) {
            case .running: d["status"] = "running"
            case .stopping: d["status"] = "stopping"
            case .stopped: d["status"] = "stopped"
            case .exited(let c): d["status"] = "exited"; if let c { d["code"] = c }
            case .crashed(let c): d["status"] = "crashed"; d["code"] = c
            }
            if let r = st.runs[s.id] {
                d["pid"] = r.pid
                d["started"] = Int(r.started.timeIntervalSince1970)
            }
            return d
        }
        let items: [[String: Any]] = wall.items.map { item in
            var d: [String: Any]
            switch item {
            case .live(let w):
                d = ["id": Int(w.id), "app": w.app, "title": w.title, "onScreen": w.onScreen,
                     "thumb": wall.thumbs[w.id] != nil, "closed": false]
                d["note"] = wall.note(w)
                d["changed"] = wall.lastChange[w.id].map { Int($0.timeIntervalSince1970) }
                d["sampled"] = wall.lastSample[w.id].map { Int($0.timeIntervalSince1970) }
            case .closed(let m):
                d = ["id": Int(m.id), "app": m.app, "title": m.title, "closed": true, "thumb": false]
                d["note"] = m.note
            }
            return d
        }
        let memo = { (m: Memo) -> [String: Any] in
            var d: [String: Any] = ["id": m.id, "text": m.text, "added": Int(m.added.timeIntervalSince1970)]
            d["done"] = m.done.map { Int($0.timeIntervalSince1970) }
            if let p = m.paused {
                d["paused"] = ["label": p.label, "closed": p.closed == true] as [String: Any]
            }
            return d
        }
        return [
            "host": hostName,
            "services": services,
            "wall": items,
            "screenOK": wall.screenOK,
            "watch": Prefs.watch,
            "staleAfter": Int(max(60, Prefs.watchInterval * 3)),
            "memos": Memos.shared.open.map(memo),
            "paused": Memos.shared.paused.map(memo),
            "done": Memos.shared.done.prefix(30).map(memo),
        ]
    }

    private func pumpLog(_ c: Client) {
        guard let id = c.logID else { return }
        let path = Store.shared.logPath(id)
        guard let fh = FileHandle(forReadingAtPath: path) else {
            if c.logOffset == nil {
                c.logOffset = 0
                send(c, ["t": "log", "id": id, "reset": true, "data": ""])
            }
            return
        }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var reset = false
        if c.logOffset == nil || size < c.logOffset! {
            c.logOffset = size > 128 << 10 ? size - (128 << 10) : 0
            c.logCarry = Data()
            reset = true
        }
        let off = c.logOffset!
        guard size > off || reset else { return }
        try? fh.seek(toOffset: off)
        let data = fh.readData(ofLength: Int(min(size - off, 256 << 10)))
        c.logOffset = off + UInt64(data.count)
        var bytes = c.logCarry + data
        let cut = utf8Cut(bytes)
        c.logCarry = bytes.subdata(in: cut..<bytes.count)
        bytes = bytes.subdata(in: 0..<cut)
        var text = String(decoding: bytes, as: UTF8.self)
        if reset && off > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }  // 去掉截断的半行
        send(c, ["t": "log", "id": id, "reset": reset, "data": text])
    }

    private func pushThumbs(_ c: Client) {
        for (id, img) in Wall.shared.thumbs where c.pending < 3 && c.sentThumbs[id] !== img {
            guard let jpg = jpeg(id, img) else { continue }
            var head = UInt32(id).bigEndian
            var d = Data(bytes: &head, count: 4)
            d.append(jpg)
            sendData(c, d, .binary)
            c.sentThumbs[id] = img
        }
    }

    /// 同一张缩略图只压一次，所有手机共用
    private func jpeg(_ id: CGWindowID, _ img: NSImage) -> Data? {
        if let (i, d) = jpegs[id], i === img { return d }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let d = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        else { return nil }
        jpegs[id] = (img, d)
        return d
    }

    private func send(_ c: Client, _ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        sendData(c, d, .text)
    }

    private func sendData(_ c: Client, _ d: Data, _ op: NWProtocolWebSocket.Opcode) {
        let ctx = NWConnection.ContentContext(identifier: "m", metadata: [NWProtocolWebSocket.Metadata(opcode: op)])
        c.pending += 1
        c.conn.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak c] _ in
            MainActor.assumeIsolated { c?.pending -= 1 }
        })
    }
}

/// 末尾可能截断了多字节 UTF-8 字符，返回能安全解码的长度
private func utf8Cut(_ d: Data) -> Int {
    let n = d.count
    var i = n - 1
    while i >= 0 && i >= n - 4 {
        let b = d[d.startIndex + i]
        if b & 0xC0 != 0x80 {
            let need = b < 0x80 ? 1 : b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
            return i + need > n ? i : n
        }
        i -= 1
    }
    return n
}

/// 本机局域网 IPv4 地址（设置里提示手动连接用）
func lanAddresses() -> [String] {
    var out: [String] = []
    var ifa: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifa) == 0 else { return [] }
    defer { freeifaddrs(ifa) }
    var p = ifa
    while let cur = p {
        defer { p = cur.pointee.ifa_next }
        let name = String(cString: cur.pointee.ifa_name)
        guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            out.append(String(cString: host))
        }
    }
    return out
}
