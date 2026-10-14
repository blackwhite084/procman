import AppKit
import Darwin
import Observation

struct Service: Codable, Identifiable, Hashable {
    var id = String(UUID().uuidString.prefix(8)).lowercased()
    var name = ""
    var cwd = ""
    var cmd = ""
    var port: Int?
    var autostart = false   // 随 Procman 启动（开机）自动运行
    var restart = false     // 异常退出自动重启
    var zshrc = true        // 先 source ~/.zshrc（conda / nvm 等）

    var url: String? { port.map { "http://127.0.0.1:\($0)" } }
    var dir: String { ((cwd.isEmpty ? "~" : cwd) as NSString).expandingTildeInPath }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        cmd = try c.decodeIfPresent(String.self, forKey: .cmd) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
        restart = try c.decodeIfPresent(Bool.self, forKey: .restart) ?? false
        zshrc = try c.decodeIfPresent(Bool.self, forKey: .zshrc) ?? true
    }
}

struct Run {
    let pid: pid_t
    let started: Date
    let own: Bool             // false = 上次 Procman 留下、本次接管的进程
    var exitCode: Int32?
    var shellDone = false
    var stopping = false
}

struct Ended { var code: Int32?; var byUser: Bool }

/// 启动前发现端口已被占用
struct Conflict: Identifiable {
    let serviceID: String
    let port: Int
    let owners: [Listener]
    var id: String { serviceID }
}

private struct SavedRun: Codable { var pid: Int32; var started: Date; var startTime: Double? }

enum Status {
    case stopped, running, stopping, exited(Int32?), crashed(Int32)
    var color: NSColor {
        switch self {
        case .running: .systemGreen
        case .stopping: .systemOrange
        case .crashed: .systemRed
        default: .tertiaryLabelColor
        }
    }
}

@MainActor @Observable
final class Store {
    static let shared = Store()
    static let background = CommandLine.arguments.contains("--background")

    var services: [Service] = []
    var runs: [String: Run] = [:]
    var ended: [String: Ended] = [:]
    var portOpen: [String: Bool] = [:]     // 所有配了端口的服务，不论是否在运行
    var portOwners: [Int: [Listener]] = [:] // 端口 -> 正在监听它的进程
    var detected: [String: [WebPort]] = [:] // 运行中服务实际监听的端口（自动检测）
    var conflict: Conflict?
    var pendingNew: Service?                // 从端口窗口「添加为服务」
    var loginItem = false
    var lastError: String?

    @ObservationIgnored var openMain: (() -> Void)?
    @ObservationIgnored var openPorts: (() -> Void)?
    @ObservationIgnored var openWindows: (() -> Void)?
    @ObservationIgnored private var ownerScanned: [Int: Date] = [:]
    @ObservationIgnored private var portCheckBusy = false
    @ObservationIgnored private var probes: [String: (WebPort, Date)] = [:]  // "pgid:port" -> HTTP 探测结果
    @ObservationIgnored private var sources: [String: DispatchSourceProcess] = [:]
    @ObservationIgnored private var crashes: [String: Int] = [:]
    @ObservationIgnored private var pendingRestart = Set<String>()
    @ObservationIgnored private var timer: Timer?

    let home: URL
    var logsDir: URL { home.appendingPathComponent("logs") }
    private var confURL: URL { home.appendingPathComponent("services.json") }
    private var stateURL: URL { home.appendingPathComponent("state.json") }
    private let plistPath = ("~/Library/LaunchAgents/com.procman.app.plist" as NSString).expandingTildeInPath

    private init() {
        let env = ProcessInfo.processInfo.environment["PROCMAN_HOME"] ?? "~/.procman"
        home = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        loginItem = FileManager.default.fileExists(atPath: plistPath)
        if let d = try? Data(contentsOf: confURL), let s = try? JSONDecoder().decode([Service].self, from: d) {
            services = s
        }
        adopt()
        for s in services where s.autostart && runs[s.id] == nil { try? start(s.id) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { Store.shared.tick() }
        }
    }

    // MARK: 查询

    func service(_ id: String) -> Service? { services.first { $0.id == id } }
    var runningCount: Int { runs.count }
    func logPath(_ id: String) -> String { logsDir.appendingPathComponent("\(id).log").path }

    /// 占用该服务端口、但不属于该服务进程组的进程
    func foreignOwners(_ id: String) -> [Listener] {
        guard let p = service(id)?.port, portOpen[id] == true else { return [] }
        let owners = portOwners[p] ?? []
        guard let r = runs[id] else { return owners }
        return owners.filter { $0.pgid != r.pid }
    }

    /// 端口被别人占着（服务没运行却在监听，或运行中但监听者不是自己）
    func portBlocked(_ id: String) -> Bool {
        guard portOpen[id] == true, let p = service(id)?.port else { return false }
        if runs[id] == nil { return true }
        return !foreignOwners(id).isEmpty && !(portOwners[p] ?? []).contains { $0.pgid == runs[id]?.pid }
    }

    /// 端口监听者属于哪个受管服务
    func serviceOwning(_ l: Listener) -> Service? {
        services.first { s in runs[s.id].map { $0.pid == l.pgid } ?? false }
    }

    func rescanPorts() { ownerScanned.removeAll(); tick() }

    struct Link: Hashable { let url: String; let port: Int; let auto: Bool }

    /// 服务的访问地址：填写的端口在前，再加上自动检测到的其它 HTTP 端口
    func links(_ id: String) -> [Link] {
        guard let s = service(id) else { return [] }
        let det = detected[id] ?? []
        var out: [Link] = []
        if let p = s.port {
            out.append(Link(url: "http://\(det.first { $0.port == p }?.host ?? "127.0.0.1"):\(p)", port: p, auto: false))
        }
        for w in det where w.http && w.port != s.port { out.append(Link(url: w.url, port: w.port, auto: true)) }
        return out
    }

    func primaryURL(_ id: String) -> String? { links(id).first?.url }

    /// 检测到在监听、但不是 HTTP 的端口
    func otherPorts(_ id: String) -> [Int] {
        (detected[id] ?? []).filter { !$0.http && $0.port != service(id)?.port }.map(\.port)
    }

    func pinPort(_ id: String, _ port: Int) {
        guard var s = service(id) else { return }
        s.port = port
        upsert(s)
    }

    func status(_ id: String) -> Status {
        if let r = runs[id] { return r.stopping ? .stopping : .running }
        guard let e = ended[id] else { return .stopped }
        if e.byUser { return .stopped }
        if let c = e.code, c != 0 { return .crashed(c) }
        return .exited(e.code)
    }

    // MARK: 增删改

    func upsert(_ s: Service) {
        if let i = services.firstIndex(where: { $0.id == s.id }) { services[i] = s } else { services.append(s) }
        save()
    }

    func delete(_ id: String) {
        stop(id)
        services.removeAll { $0.id == id }
        ended[id] = nil
        save()
        try? FileManager.default.removeItem(atPath: logPath(id))
    }

    func move(from: IndexSet, to: Int) {
        services.move(fromOffsets: from, toOffset: to)
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(services).write(to: confURL, options: .atomic)
    }

    private func saveState() {
        let saved = runs.mapValues { SavedRun(pid: $0.pid, started: $0.started, startTime: procStartTime($0.pid)) }
        try? JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
    }

    // MARK: 启停

    func start(_ id: String) throws {
        guard let s = service(id), runs[id] == nil else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: s.dir, isDirectory: &isDir), isDir.boolValue else {
            throw err("目录不存在：\(s.dir)")
        }
        let log = logPath(id)
        if let size = (try? FileManager.default.attributesOfItem(atPath: log))?[.size] as? Int, size > 20 << 20 {
            try? FileManager.default.removeItem(atPath: log + ".1")
            try? FileManager.default.moveItem(atPath: log, toPath: log + ".1")
        }
        appendLog(id, "\n===== [\(timestamp())] 启动  cwd=\(s.dir) =====\n$ \(s.cmd)\n")
        if let p = s.port, portListening(p) {
            let who = (portOwners[p] ?? []).map { "\($0.command)(PID \($0.pid))" }.joined(separator: ", ")
            appendLog(id, "===== 警告：端口 \(p) 已被占用\(who.isEmpty ? "" : "：" + who) =====\n")
        }

        var script = "cd -- \(shq(s.dir)) || exit 1\n"
        if s.zshrc { script += "[ -f ~/.zshrc ] && source ~/.zshrc >/dev/null 2>&1\n" }
        script += s.cmd
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PROCMAN"] = "1"
        if env["LANG"] == nil { env["LANG"] = "zh_CN.UTF-8" }
        env["PROCMAN_HOME"] = nil

        let pid = try spawn(["/bin/zsh", "-l", "-c", script], env: env, log: log)
        runs[id] = Run(pid: pid, started: Date(), own: true)
        ended[id] = nil
        lastError = nil
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { Store.shared.check(id) } }
        src.resume()
        sources[id] = src
        saveState()
    }

    func stop(_ id: String) {
        guard var r = runs[id], !r.stopping else { return }
        r.stopping = true
        runs[id] = r
        let pid = r.pid
        kill(-pid, SIGTERM)
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline && groupAlive(pid) { usleep(150_000) }
            if groupAlive(pid) { kill(-pid, SIGKILL) }
        }
    }

    func restart(_ id: String) {
        if runs[id] == nil { tryStart(id); return }
        pendingRestart.insert(id)
        stop(id)
    }

    /// interactive: 用户手动点的启动，端口被占时弹窗询问；自动启动/自动重启只在日志里警告
    func tryStart(_ id: String, interactive: Bool = true) {
        if interactive, runs[id] == nil, let p = service(id)?.port, portListening(p) {
            let owners = listListeners(port: p)
            portOwners[p] = owners
            conflict = Conflict(serviceID: id, port: p, owners: owners)
            openMain?()
            return
        }
        do { try start(id) } catch { lastError = error.localizedDescription; NSSound.beep() }
    }

    /// 结束占用端口的进程，等端口释放后启动服务
    func killOwnersThenStart(_ c: Conflict) {
        c.owners.forEach { killProcess($0.pid) }
        let port = c.port
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(7)
            while Date() < deadline && portListening(port) { usleep(200_000) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Store.shared.tryStart(c.serviceID, interactive: false) }
            }
        }
    }

    func killListener(_ l: Listener, force: Bool = false) {
        killProcess(l.pid, force: force)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { Store.shared.rescanPorts() }
        }
    }

    func toggle(_ id: String) { runs[id] == nil ? tryStart(id) : stop(id) }

    func stopAllAndQuit() {
        runs.keys.forEach(stop)
        var waited = 0
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
            MainActor.assumeIsolated {
                waited += 1
                if Store.shared.runs.isEmpty || waited > 60 { t.invalidate(); NSApp.terminate(nil) }
            }
        }
    }

    // MARK: 状态轮询

    private func tick() {
        for id in Array(runs.keys) { check(id) }
        let checks = services.compactMap { s in s.port.map { (s.id, $0) } }
        let groups = runs.map { ($0.key, $0.value.pid) }
        guard !(checks.isEmpty && groups.isEmpty), !portCheckBusy else { return }
        portCheckBusy = true
        // 端口在监听时才跑 lsof 查是谁（3 秒缓存），平时只是一次本地 connect
        let now = Date()
        let stale = Set(checks.map(\.1).filter { now.timeIntervalSince(ownerScanned[$0] ?? .distantPast) > 3 })
        // HTTP 探测结果：是 web 就一直缓存，不是的话 20 秒后重试（可能还没启动完）
        let cached = probes.filter { $0.value.0.http || now.timeIntervalSince($0.value.1) < 20 }.mapValues(\.0)
        DispatchQueue.global(qos: .utility).async {
            let open = checks.map { ($0.0, $0.1, portListening($0.1)) }
            var owners: [Int: [Listener]] = [:]
            for (_, p, o) in open where o && stale.contains(p) && owners[p] == nil { owners[p] = listListeners(port: p) }
            var found: [String: [WebPort]] = [:]
            var newProbes: [String: WebPort] = [:]
            for (id, pg) in groups {
                found[id] = listeningPorts(pgid: pg).map { p in
                    let key = "\(pg):\(p)"
                    if let w = cached[key] { return w }
                    let w = probeHTTP(p)
                    newProbes[key] = w
                    return w
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let st = Store.shared
                    st.portCheckBusy = false
                    for (id, p, o) in open {
                        if st.portOpen[id] != o { st.portOpen[id] = o }
                        if !o, st.portOwners[p] != nil { st.portOwners[p] = nil; st.ownerScanned[p] = nil }
                    }
                    for (p, l) in owners {
                        st.ownerScanned[p] = now
                        if st.portOwners[p] != l { st.portOwners[p] = l }
                    }
                    for (k, w) in newProbes { st.probes[k] = (w, now) }
                    for (id, ws) in found where st.runs[id] != nil && st.detected[id] != ws {
                        st.detected[id] = ws
                        if debugLog { print("detected", id, ws.map { "\($0.port)\($0.http ? "/http" : "")" }, terminator: "\n") }
                    }
                    if debugLog { print("blocked", st.services.filter { st.portBlocked($0.id) }.map(\.id), st.portOwners.mapValues { $0.map(\.command) }); fflush(stdout) }
                }
            }
        }
    }

    private func check(_ id: String) {
        guard var r = runs[id] else { return }
        if r.own && !r.shellDone {
            var st: Int32 = 0
            guard waitpid(r.pid, &st, WNOHANG) == r.pid else { return }
            r.shellDone = true
            r.exitCode = (st & 0x7f) == 0 ? (st >> 8) & 0xff : -(st & 0x7f)
            runs[id] = r
        }
        if !groupAlive(r.pid) { finalize(id) }  // shell 退了还要等后台子进程也退
    }

    private func finalize(_ id: String) {
        guard let r = runs.removeValue(forKey: id) else { return }
        sources.removeValue(forKey: id)?.cancel()
        portOpen[id] = nil
        detected[id] = nil
        probes = probes.filter { !$0.key.hasPrefix("\(r.pid):") }
        ended[id] = Ended(code: r.exitCode, byUser: r.stopping)
        appendLog(id, "===== [\(timestamp())] 已退出 code=\(r.exitCode.map(String.init) ?? "?")\(r.stopping ? "（手动停止）" : "") =====\n")
        saveState()

        if pendingRestart.remove(id) != nil { tryStart(id, interactive: false); return }
        guard let s = service(id), s.restart, !r.stopping, r.exitCode != 0 else { return }
        let n = Date().timeIntervalSince(r.started) < 15 ? (crashes[id] ?? 0) + 1 : 1
        crashes[id] = n
        if n > 5 { appendLog(id, "===== 连续快速崩溃 5 次，停止自动重启 =====\n"); return }
        appendLog(id, "===== 3 秒后自动重启（第 \(n) 次）=====\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                let st = Store.shared
                if st.runs[id] == nil, st.service(id)?.restart == true, !(st.ended[id]?.byUser ?? true) { st.tryStart(id, interactive: false) }
            }
        }
    }

    /// Procman 重启后接管仍在运行的服务（输出本来就直接写日志文件，不受影响）
    private func adopt() {
        guard let d = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode([String: SavedRun].self, from: d) else { return }
        for (id, s) in saved where service(id) != nil && groupAlive(s.pid) {
            if let t = s.startTime, let now = procStartTime(s.pid), abs(t - now) > 1 { continue }  // pid 被复用
            runs[id] = Run(pid: s.pid, started: s.started, own: false, shellDone: true)
        }
        saveState()
    }

    // MARK: 开机启动

    func setLoginItem(_ on: Bool) {
        if on {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": "com.procman.app",
                "ProgramArguments": [exe, "--background"],
                "RunAtLoad": true,
                "AbandonProcessGroup": true,
                "ProcessType": "Interactive",
            ]
            try? FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            (plist as NSDictionary).write(toFile: plistPath, atomically: true)
        } else {
            try? FileManager.default.removeItem(atPath: plistPath)
        }
        loginItem = FileManager.default.fileExists(atPath: plistPath)
    }

    // MARK: 工具

    func appendLog(_ id: String, _ text: String) {
        let path = logPath(id)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    func clearLog(_ id: String) { truncate(logPath(id), 0) }
}

// MARK: - 进程底层

private let debugLog = ProcessInfo.processInfo.environment["PROCMAN_DEBUG"] != nil

private func err(_ msg: String) -> NSError {
    NSError(domain: "procman", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
}

private func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}

private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// posix_spawn + setsid：子进程自成进程组，stdout/stderr 直接写日志文件，Procman 退出不影响它
private func spawn(_ args: [String], env: [String: String], log: String) throws -> pid_t {
    var fa: posix_spawn_file_actions_t?
    var attr: posix_spawnattr_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawnattr_init(&attr)
    defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    var all = sigset_t(), none = sigset_t()
    sigfillset(&all)
    sigemptyset(&none)
    posix_spawnattr_setsigdefault(&attr, &all)
    posix_spawnattr_setsigmask(&attr, &none)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                          | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    let argv = args.map { strdup($0) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, args[0], &fa, &attr, argv, envp)
    if rc != 0 { throw err("启动失败：\(String(cString: strerror(rc)))") }
    return pid
}

nonisolated func groupAlive(_ pgid: pid_t) -> Bool {
    kill(-pgid, 0) == 0 || errno == EPERM
}

private func procStartTime(_ pid: pid_t) -> Double? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
}

nonisolated func portListening(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}
