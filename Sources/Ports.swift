import AppKit
import Darwin

/// 正在监听 TCP 端口的进程
struct Listener: Identifiable, Hashable, Sendable {
    let pid: pid_t
    let port: Int
    var command: String
    var user: String
    var addrs: [String] = []
    var args = ""
    var pgid: pid_t = 0
    var id: String { "\(pid):\(port)" }
}

nonisolated func sh(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// lsof 列出监听中的端口；port 为 nil 时列出全部。只能看到当前用户有权限查看的进程。
nonisolated func listListeners(port: Int? = nil) -> [Listener] {
    let target = port.map { "-iTCP:\($0)" } ?? "-iTCP"
    let out = sh("/usr/sbin/lsof", ["-nP", "+c", "0", target, "-sTCP:LISTEN", "-FpcLn"])
    var byKey: [String: Listener] = [:]
    var order: [String] = []
    var pid: pid_t = 0, cmd = "", user = ""
    for line in out.split(separator: "\n") {
        guard let tag = line.first else { continue }
        let v = String(line.dropFirst())
        switch tag {
        case "p": pid = pid_t(v) ?? 0; cmd = ""; user = ""
        case "c": cmd = v
        case "L": user = v
        case "n":
            guard let i = v.lastIndex(of: ":"), let p = Int(v[v.index(after: i)...]) else { continue }
            let key = "\(pid):\(p)"
            if byKey[key] == nil {
                byKey[key] = Listener(pid: pid, port: p, command: cmd, user: user)
                order.append(key)
            }
            let addr = String(v[..<i])
            if !byKey[key]!.addrs.contains(addr) { byKey[key]!.addrs.append(addr) }
        default: break
        }
    }
    var list = order.map { byKey[$0]! }
    let pids = Set(list.map(\.pid))
    guard !pids.isEmpty else { return [] }
    var args: [pid_t: String] = [:]
    let ps = sh("/bin/ps", ["-ww", "-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")])
    for l in ps.split(separator: "\n") {
        let t = l.trimmingCharacters(in: .whitespaces)
        if let sp = t.firstIndex(of: " "), let p = pid_t(t[..<sp]) {
            args[p] = t[sp...].trimmingCharacters(in: .whitespaces)
        }
    }
    for i in list.indices {
        list[i].args = args[list[i].pid] ?? list[i].command
        list[i].pgid = pgidOf(list[i].pid) ?? 0
    }
    return list.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
}

nonisolated func pgidOf(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_pgid
}

nonisolated func procCwd(_ pid: pid_t) -> String? {
    let out = sh("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
    return out.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
}

/// 先 SIGTERM，5 秒还活着再 SIGKILL；无权限时请求管理员密码
@MainActor
func killProcess(_ pid: pid_t, force: Bool = false) {
    if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
        if errno == EPERM {
            var e: NSDictionary?
            NSAppleScript(source: "do shell script \"kill -9 \(pid)\" with administrator privileges")?
                .executeAndReturnError(&e)
        }
        return
    }
    if !force {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}

// MARK: - 自动检测服务监听的端口（libproc，不起子进程）

/// 进程组内所有进程正在 LISTEN 的 TCP 端口
nonisolated func listeningPorts(pgid: pid_t) -> [Int] {
    var pids = [pid_t](repeating: 0, count: 512)
    _ = proc_listpgrppids(pgid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var ports = Set<Int>()
    for pid in pids where pid > 0 {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { continue }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { continue }
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
                  si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == 1 /* TSI_S_LISTEN */ else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
    }
    return ports.sorted()
}

struct WebPort: Hashable, Sendable {
    let port: Int
    let http: Bool
    let host: String
    var url: String { "http://\(host):\(port)" }
}

/// 发一个 HTTP 请求看是不是 web 端口；IPv4 不通再试 ::1（只监听 localhost 的 IPv6 服务）
nonisolated func probeHTTP(_ port: Int) -> WebPort {
    for (host, family) in [("127.0.0.1", AF_INET), ("localhost", AF_INET6)] {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { continue }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let ok: Bool
        if family == AF_INET {
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = in_port_t(UInt16(port).bigEndian)
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        } else {
            var a = sockaddr_in6()
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = in_port_t(UInt16(port).bigEndian)
            a.sin6_addr = in6addr_loopback
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 } }
        }
        guard ok else { continue }
        let req = "HEAD / HTTP/1.0\r\nHost: \(host):\(port)\r\n\r\n"
        _ = req.withCString { send(fd, $0, strlen($0), 0) }
        var buf = [UInt8](repeating: 0, count: 16)
        let n = recv(fd, &buf, buf.count, 0)
        let http = n >= 5 && String(decoding: buf.prefix(5), as: UTF8.self) == "HTTP/"
        return WebPort(port: port, http: http, host: host)
    }
    return WebPort(port: port, http: false, host: "127.0.0.1")
}
