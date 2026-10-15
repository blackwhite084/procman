import AppKit
import ApplicationServices
import Observation
import ScreenCaptureKit

// MARK: - 窗口枚举

struct WinInfo: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let bundle: String?
    let title: String       // 需要「屏幕录制」权限，没有时为空
    let bounds: CGRect
    let onScreen: Bool      // false = 在其他桌面空间或已最小化
    var label: String { title.isEmpty ? app : title }
}

/// onScreenOnly 时系统保证按前后层叠顺序返回（前面的在前），但只含当前空间的窗口
nonisolated func listWindows(onScreenOnly: Bool = false) -> [WinInfo] {
    var opts: CGWindowListOption = .excludeDesktopElements
    if onScreenOnly { opts.insert(.optionOnScreenOnly) }
    guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    let me = getpid()
    var apps: [pid_t: NSRunningApplication] = [:]
    var out: [WinInfo] = []
    for w in raw {
        guard (w[kCGWindowLayer as String] as? Int) == 0,   // 菜单栏 / Dock / 悬浮面板都在别的层
              let id = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me else { continue }
        if let a = w[kCGWindowAlpha as String] as? Double, a <= 0.01 { continue }
        let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        guard b.width >= 120, b.height >= 80 else { continue }
        if apps[pid] == nil { apps[pid] = NSRunningApplication(processIdentifier: pid) }
        let app = apps[pid]
        // 只要会出现在 Dock 里的正常 app：输入法、UI 服务之类的后台进程也带一堆 layer 0 窗口
        if let app, app.activationPolicy != .regular { continue }
        out.append(WinInfo(id: id, pid: pid,
                           app: app?.localizedName ?? w[kCGWindowOwnerName as String] as? String ?? "?",
                           bundle: app?.bundleIdentifier,
                           title: w[kCGWindowName as String] as? String ?? "",
                           bounds: b,
                           onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false))
    }
    return out
}

// MARK: - 精确跳转（辅助功能 API）

// 私有 API：把 AXUIElement 映射成 CGWindowID。AltTab / Rectangle 都靠它切准同名窗口，
// 自 10.5 起一直稳定存在；万一失效，下面的几何匹配兜底
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

private func axWindowID(_ e: AXUIElement) -> CGWindowID? {
    var id = CGWindowID(0)
    return _AXUIElementGetWindow(e, &id) == .success && id != 0 ? id : nil
}

private func axValue(_ e: AXUIElement, _ attr: String) -> AXValue? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &raw) == .success, let raw,
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    return (raw as! AXValue)
}

private func axFrame(_ e: AXUIElement) -> CGRect? {
    var p = CGPoint.zero, s = CGSize.zero
    guard let pv = axValue(e, kAXPositionAttribute), AXValueGetValue(pv, .cgPoint, &p),
          let sv = axValue(e, kAXSizeAttribute), AXValueGetValue(sv, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

struct AXMatch {
    var error: AXError = .success
    var windows: [AXUIElement] = []
    var target: AXUIElement?
    var by = "none"
}

/// 在 app 的 AX 窗口里找到对应 CGWindowID 的那个。匹配顺序：窗口 ID → 几何位置（容差 6 点）→ 该 app 只有一个窗口。
/// AX 只列出当前桌面空间的窗口，所以后两种兜底只对当前空间的窗口做，否则会匹配到同 app 的别的窗口
func axMatch(_ w: WinInfo) -> AXMatch {
    var m = AXMatch()
    var raw: CFTypeRef?
    m.error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(w.pid), kAXWindowsAttribute as CFString, &raw)
    guard m.error == .success, let wins = raw as? [AXUIElement] else { return m }
    m.windows = wins
    let near = { (r: CGRect) in
        abs(r.minX - w.bounds.minX) <= 6 && abs(r.minY - w.bounds.minY) <= 6
            && abs(r.width - w.bounds.width) <= 6 && abs(r.height - w.bounds.height) <= 6
    }
    if let t = wins.first(where: { axWindowID($0) == w.id }) { m.target = t; m.by = "windowID" }
    else if w.onScreen, let t = wins.first(where: { axFrame($0).map(near) ?? false }) { m.target = t; m.by = "geometry" }
    else if w.onScreen, wins.count == 1 { m.target = wins[0]; m.by = "only-window" }
    return m
}

func axDescribe(_ e: AXUIElement) -> String {
    let f = axFrame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "?"
    return "id=\(axWindowID(e).map(String.init) ?? "?") frame=\(f)"
}

// MARK: 跨桌面空间跳转（SkyLight 私有 API，AltTab 同款）
//
// AX 拿不到其他桌面空间的窗口，所以只靠 AX 的话跨空间只能切到 app。
// _SLPSSetFrontProcessWithOptions 按窗口 ID 把那个窗口所在的进程提到最前，系统会自己切到它的空间；
// 再补两条「让它成为 key window」的事件记录。运行时 dlsym 取符号，取不到就退回 AX

private typealias SetFrontFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> Int32
private typealias PostEventFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
private typealias PSNForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

private let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let slpsSetFront = dlsym(skylight, "_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SetFrontFn.self) }
private let slpsPostEvent = dlsym(skylight, "SLPSPostEventRecordTo").map { unsafeBitCast($0, to: PostEventFn.self) }
private let psnForPID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map { unsafeBitCast($0, to: PSNForPIDFn.self) }

var skylightAvailable: Bool { slpsSetFront != nil && slpsPostEvent != nil && psnForPID != nil }

/// 成功返回 true
private func skylightFront(_ w: WinInfo) -> Bool {
    guard let slpsSetFront, let slpsPostEvent, let psnForPID else { return false }
    var psn = ProcessSerialNumber()
    guard withUnsafeMutableBytes(of: &psn, { psnForPID(w.pid, $0.baseAddress!) }) == 0 else { return false }
    return withUnsafeMutableBytes(of: &psn) { p in
        guard slpsSetFront(p.baseAddress!, w.id, 0x200) == 0 else { return false }   // 0x200 = userGenerated
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: w.id) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = slpsPostEvent(p.baseAddress!, &bytes)
        bytes[0x08] = 0x02
        _ = slpsPostEvent(p.baseAddress!, &bytes)
        return true
    }
}

/// 跳到指定窗口：SkyLight 按窗口 ID 提到最前（能跨桌面空间），AX 负责取消最小化和在 app 内部提窗口。
/// 两条路都没成就只激活 app。成功返回 nil，否则返回给用户看的原因
@discardableResult
func focusWindow(_ w: WinInfo) -> String? {
    guard let app = NSRunningApplication(processIdentifier: w.pid) else { return "\(w.app) 已经退出了" }
    if app.isHidden { app.unhide() }
    let m = axMatch(w)
    if let t = m.target {
        AXUIElementSetAttributeValue(t, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    let front = skylightFront(w)
    if let t = m.target {
        // 先在 app 内部把它提到最前再激活 app，否则多窗口 app 会切到它自己记的「上一个」窗口
        AXUIElementSetAttributeValue(t, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(t, kAXRaiseAction as CFString)
    }
    if !front { app.activate() }
    if debugLog { print("focus", w.id, w.app, "skylight=\(front)", "ax=\(m.by)", "axErr=\(m.error.rawValue)", m.windows.map(axDescribe)); fflush(stdout) }
    if front || m.target != nil { return nil }
    return AXIsProcessTrusted() ? "没能定位到具体窗口，只切到了 \(w.app)" : "缺「辅助功能」权限，只能切到 app，无法精确到窗口"
}

/// 当前最前面的窗口：优先用 AX 拿焦点窗口（精确），退回屏上最前面属于该 app 的窗口
func frontmostWindow() -> WinInfo? {
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
    let pid = app.processIdentifier
    let onScreen = listWindows(onScreenOnly: true)
    var raw: CFTypeRef?
    if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &raw) == .success,
       let raw, CFGetTypeID(raw) == AXUIElementGetTypeID(), let id = axWindowID(raw as! AXUIElement),
       let w = onScreen.first(where: { $0.id == id }) {
        return w
    }
    return onScreen.first { $0.pid == pid }
}

// MARK: - 权限

enum Permission {
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestScreen() {
        if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
    }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openSettings("Privacy_Accessibility") }
    }

    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// 权限改动要重启进程才生效。服务进程是独立进程组，重启 Procman 不影响它们
func relaunch() {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

// MARK: - 截图（ScreenCaptureKit）

/// ScreenCaptureKit 偶尔会一直不返回（实测：截其他桌面空间的窗口时），给每次调用套个超时，
/// 免得一个窗口卡住整个刷新循环。超时后那次调用会泄漏在后台，所以超时的窗口要退避一段时间再试
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

nonisolated func withTimeout<T>(_ seconds: Double, _ op: @escaping () async -> T?) async -> T? {
    let once = Once()
    return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
        Task { let r = await op(); if once.take() { c.resume(returning: r) } }
        Task { try? await Task.sleep(for: .seconds(seconds)); if once.take() { c.resume(returning: nil) } }
    }
}

/// 同一时间只允许一个 ScreenCaptureKit 请求在跑。
/// 超时只是我们不等了，请求本身还挂在系统的 replayd 里；继续发新请求会越堆越多，
/// 实测会把 replayd 堵死，连系统自带的 screencapture 都截不了。所以没返回之前一律不发新的
private final class SCGate: @unchecked Sendable {
    static let shared = SCGate()
    private let lock = NSLock()
    private var busy = false
    func enter() -> Bool { lock.lock(); defer { lock.unlock() }; if busy { return false }; busy = true; return true }
    func leave() { lock.lock(); busy = false; lock.unlock() }
}

/// 过闸门的 ScreenCaptureKit 调用：闸门被占（上一个请求还没回来）直接返回 nil
nonisolated func gated<T>(_ seconds: Double, _ op: @escaping () async -> T?) async -> T? {
    guard SCGate.shared.enter() else { return nil }
    return await withTimeout(seconds) {
        let r = await op()
        SCGate.shared.leave()
        return r
    }
}

enum Shot { case image(NSImage, [UInt8]), failed }

/// 画面指纹：缩成 64×40 灰度。只用来判断「画面动没动」，和截图尺寸无关
private let fpW = 64, fpH = 40

nonisolated func fingerprint(_ img: CGImage) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: fpW * fpH)
    px.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: fpW, height: fpH, bitsPerComponent: 8, bytesPerRow: fpW,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: fpW, height: fpH))
    }
    return px
}

/// 亮度变化超过 20 的格子占比 ≥ ratio（默认 3%）就算在动；光标闪烁、转圈动画这种小范围变化不算
nonisolated func changed(_ a: [UInt8], _ b: [UInt8], ratio: Double = Prefs.motionRatio) -> Bool {
    guard a.count == b.count else { return true }
    let need = max(1, Int((Double(a.count) * ratio).rounded(.up)))
    var n = 0
    for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 20 {
        n += 1
        if n >= need { return true }
    }
    return false
}

/// SCShareableContent 很重（实测 0.8–3 秒），而且取的过程中会把正在进行的截图一起拖住。
/// 所以缓存起来，只在出现没见过的窗口、或窗口尺寸变了（截图比例会错）时才重取
@MainActor private enum SCCache {
    static var windows: [CGWindowID: SCWindow] = [:]
    static var lastTry = Date.distantPast

    static func get(_ wins: [WinInfo]) async -> [SCWindow] {
        let stale = wins.contains { w in
            guard let c = windows[w.id] else { return true }
            return abs(c.frame.width - w.bounds.width) > 1 || abs(c.frame.height - w.bounds.height) > 1
        }
        // 取不到的窗口（比如刚关掉）别每轮都重取
        if stale, Date().timeIntervalSince(lastTry) > 5 {
            lastTry = Date()
            if let content = await gated(10, { try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }) {
                windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
        return wins.compactMap { windows[$0.id] }
    }
}

/// 截一批窗口。返回 .failed 的是超时或出错的，调用方保留旧图并退避
@MainActor
func capture(_ wins: [WinInfo], maxEdge: CGFloat) async -> [CGWindowID: Shot] {
    guard !wins.isEmpty else { return [:] }
    var out: [CGWindowID: Shot] = [:]
    for w in await SCCache.get(wins) {
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let r = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        guard r.width > 0, r.height > 0 else { continue }
        let k = min(scale, maxEdge / max(r.width, r.height))
        let cfg = SCStreamConfiguration()
        cfg.width = Int(r.width * k)
        cfg.height = Int(r.height * k)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        let img = await gated(5) { try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) }
        out[w.windowID] = img.map { .image(NSImage(cgImage: $0, size: r.size), fingerprint($0)) } ?? .failed
    }
    return out
}

// MARK: - 设置项

enum Prefs {
    static var thumbs: Bool { UserDefaults.standard.object(forKey: "wallThumbs") as? Bool ?? true }
    static var interval: Double { max(1, UserDefaults.standard.object(forKey: "wallInterval") as? Double ?? 2) }
    static var motionRatio: Double { UserDefaults.standard.object(forKey: "wallMotion") as? Double ?? 0.03 }
    static var watch: Bool { UserDefaults.standard.object(forKey: "wallWatch") as? Bool ?? true }
    static var watchInterval: Double { max(2, UserDefaults.standard.object(forKey: "wallWatchInterval") as? Double ?? 10) }
    static var allSpaces: Bool { UserDefaults.standard.object(forKey: "allSpaces") as? Bool ?? true }
}

// MARK: - 监控名单

struct AppMark: Codable, Hashable {
    var bundle: String
    var name: String
    var note: String?
    var added: Date?
}

struct WinMark: Codable, Hashable {
    var id: CGWindowID
    var bundle: String?
    var app: String
    var title: String
    var note: String?
    var added: Date?
}

/// 窗口级按窗口 ID 记（app 重启后失效，正好适合「等这个任务跑完」）；app 级按 bundle ID 记。
/// 格式兼容 taskwall 的 ~/.taskwall/marks.json（多了可选的 note / added），首次运行会直接导入
struct Marks: Codable {
    var apps: [AppMark] = []
    var windows: [WinMark] = []
}

enum Via { case window, app }

@MainActor @Observable
final class Wall {
    static let shared = Wall()

    var marks = Marks()
    var windows: [WinInfo] = []
    var thumbs: [CGWindowID: NSImage] = [:]
    var selection: CGWindowID?
    var editing: CGWindowID?          // 窗口墙里正在编辑备注的那一格
    var screenOK = Permission.screen
    var axOK = Permission.accessibility

    var lastChange: [CGWindowID: Date] = [:]   // 画面最后一次变化
    var lastSample: [CGWindowID: Date] = [:]   // 最后一次截图成功
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var liveRequested = false   // 窗口墙页正在显示
    @ObservationIgnored private var kick = false             // 立即开始下一轮
    /// 正在看窗口墙的手机数，有人看就按前台间隔截清晰缩略图
    @ObservationIgnored var remoteViewers = 0 { didSet { if remoteViewers > oldValue { kick = true } } }
    @ObservationIgnored private var prints: [CGWindowID: (fp: [UInt8], big: Bool)] = [:]
    @ObservationIgnored private var backoff: [CGWindowID: Date] = [:]   // 截图超时的窗口，到这个时间前不再截
    @ObservationIgnored private var icons: [pid_t: NSImage] = [:]
    @ObservationIgnored private var goneSince: [CGWindowID: Date] = [:]   // 标记的窗口从什么时候起找不到了
    private var url: URL { Store.shared.home.appendingPathComponent("marks.json") }

    private init() {
        let old = URL(fileURLWithPath: ("~/.taskwall/marks.json" as NSString).expandingTildeInPath)
        for u in [url, old] {
            if let d = try? Data(contentsOf: u), let m = try? Self.decoder.decode(Marks.self, from: d) {
                marks = m
                if u == old { save() }
                break
            }
        }
        refresh()
    }

    // MARK: 查询

    func via(_ w: WinInfo) -> Via? {
        if marks.windows.contains(where: { $0.id == w.id }) { return .window }
        if let b = w.bundle, marks.apps.contains(where: { $0.bundle == b }) { return .app }
        return nil
    }

    func mark(_ w: WinInfo) -> WinMark? { marks.windows.first { $0.id == w.id } }
    func appMark(_ bundle: String?) -> AppMark? { bundle.flatMap { b in marks.apps.first { $0.bundle == b } } }

    /// 窗口自己的备注优先，没有再用整个 app 的
    func note(_ w: WinInfo) -> String? { mark(w)?.note ?? appMark(w.bundle)?.note }
    func added(_ w: WinInfo) -> Date? { mark(w)?.added ?? appMark(w.bundle)?.added }

    /// 写到窗口是怎么被标记的那一层上；空字符串 = 删除备注
    func setNote(_ w: WinInfo, _ text: String) {
        if via(w) == .app, let b = w.bundle { setAppNote(b, text) } else { setNote(id: w.id, text) }
    }

    func setNote(id: CGWindowID, _ text: String) {
        guard let i = marks.windows.firstIndex(where: { $0.id == id }) else { return }
        marks.windows[i].note = clean(text)
        save()
    }

    func setAppNote(_ bundle: String, _ text: String) {
        guard let i = marks.apps.firstIndex(where: { $0.bundle == bundle }) else { return }
        marks.apps[i].note = clean(text)
        save()
    }

    private func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func appMarked(_ bundle: String?) -> Bool { bundle.map { b in marks.apps.contains { $0.bundle == b } } ?? false }

    /// 监控中的窗口，按标记顺序排：单个窗口在前，整个 app 的按 app 标记顺序跟在后面
    var monitored: [WinInfo] {
        let order = Dictionary(marks.windows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        let appOrder = Dictionary(marks.apps.enumerated().map { ($1.bundle, $0) }, uniquingKeysWith: min)
        return windows.compactMap { w -> (Int, CGWindowID, WinInfo)? in
            if let i = order[w.id] { return (i, w.id, w) }
            if let b = w.bundle, let i = appOrder[b] { return (marks.windows.count + i, w.id, w) }
            return nil
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
    }

    /// 窗口已经关掉的单窗口标记。带备注的会留在窗口墙上当待办，不会被自动清理
    var stale: [WinMark] {
        let live = Set(windows.map(\.id))
        return marks.windows.filter { !live.contains($0.id) }
    }

    func icon(_ pid: pid_t) -> NSImage {
        if let i = icons[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!
        icons[pid] = i
        return i
    }

    // MARK: 增删

    @discardableResult
    func toggle(_ w: WinInfo) -> Bool {
        if let i = marks.windows.firstIndex(where: { $0.id == w.id }) {
            marks.windows.remove(at: i)
        } else {
            marks.windows.append(WinMark(id: w.id, bundle: w.bundle, app: w.app, title: w.title, added: Date()))
        }
        save()
        return via(w) == .window
    }

    @discardableResult
    func toggleApp(bundle: String, name: String) -> Bool {
        if let i = marks.apps.firstIndex(where: { $0.bundle == bundle }) {
            marks.apps.remove(at: i)
        } else {
            marks.apps.append(AppMark(bundle: bundle, name: name, added: Date()))
        }
        save()
        return appMarked(bundle)
    }

    /// 网格里的「取消监控」：是哪种方式标记的就撤哪种
    func unmark(_ w: WinInfo) {
        switch via(w) {
        case .window: toggle(w)
        case .app: if let b = w.bundle { toggleApp(bundle: b, name: w.app) }
        case nil: break
        }
    }

    func remove(id: CGWindowID) {
        marks.windows.removeAll { $0.id == id }
        save()
    }

    /// 暂停监控：从窗口墙摘下来转成一条「已暂停」待办。整个 app 监控的就暂停整个 app
    func pause(_ item: WallItem) {
        var p: Paused
        var note: String?
        switch item {
        case .live(let w) where via(w) == .app:
            guard let b = w.bundle, let i = marks.apps.firstIndex(where: { $0.bundle == b }) else { return }
            let m = marks.apps.remove(at: i)
            p = Paused(app: m, label: "整个 \(m.name)")
            note = m.note
        case .live(let w):
            guard let i = marks.windows.firstIndex(where: { $0.id == w.id }) else { return }
            var m = marks.windows.remove(at: i)
            if !w.title.isEmpty { m.title = w.title }
            p = Paused(window: m, label: m.title.isEmpty ? m.app : "\(m.app) — \(m.title)")
            note = m.note
        case .closed(let m):
            marks.windows.removeAll { $0.id == m.id }
            p = Paused(window: m, label: m.title.isEmpty ? m.app : "\(m.app) — \(m.title)", closed: true)
            note = m.note
        }
        save()
        if selection == item.id { selection = nil }
        Memos.shared.addPaused(note ?? p.label, p)
    }

    /// 恢复监控；待办文字改过就当作新的备注。窗口在暂停期间换了 id 的，交给 reattach 找回
    func restore(_ p: Paused, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = t != p.label && !t.isEmpty
        if var m = p.app {
            if edited { m.note = t }
            if !marks.apps.contains(where: { $0.bundle == m.bundle }) { marks.apps.append(m) }
        } else if var m = p.window {
            if edited { m.note = t }
            if !marks.windows.contains(where: { $0.id == m.id }) { marks.windows.append(m) }
        }
        save()
        reattach()
    }

    /// keepNotes: 只清没写备注的失效条目
    func prune(keepNotes: Bool) {
        let live = Set(windows.map(\.id))
        marks.windows.removeAll { !live.contains($0.id) && !(keepNotes && $0.note != nil) }
        save()
    }

    private static let decoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(marks).write(to: url, options: .atomic)
    }

    // MARK: 快捷键动作

    func toggleFrontmostWindow() {
        guard let w = frontmostWindow() else { HUD.show("没找到当前窗口", icon: "questionmark.circle"); return }
        if via(w) == .app {
            HUD.show("整个 \(w.app) 已在监控中（\(HotKeys.shared.display(.markApp)) 取消）", icon: "eye")
            return
        }
        let what = "\(w.app)\(w.title.isEmpty ? "" : " — \(w.title)")"
        if toggle(w) {
            NotePrompt.shared.ask(title: "已加入监控：\(what)") { Wall.shared.setNote(id: w.id, $0) }
        } else {
            HUD.show("已移出监控：\(what)", icon: "eye.slash")
        }
    }

    func toggleFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let b = app.bundleIdentifier else { HUD.show("没找到当前 app", icon: "questionmark.circle"); return }
        let name = app.localizedName ?? b
        if toggleApp(bundle: b, name: name) {
            NotePrompt.shared.ask(title: "已加入监控：整个 \(name)") { Wall.shared.setAppNote(b, $0) }
        } else {
            HUD.show("已移出监控：整个 \(name)", icon: "eye.slash")
        }
    }

    // MARK: 刷新

    func refresh() {
        let list = listWindows()
        if list != windows { windows = list; reattach() }
        autoPause()
        screenOK = Permission.screen
        axOK = Permission.accessibility
    }

    /// 窗口关掉 20 秒以上、写了备注的标记，转成「窗口已关闭」待办（窗口重开时自动放回墙上）。
    /// 没写备注的留在「管理监控」的失效列表里，窗口重开同样会被找回
    private func autoPause() {
        let now = Date()
        let lost = stale
        let ids = Set(lost.map(\.id))
        goneSince = goneSince.filter { ids.contains($0.key) }
        for m in lost where m.note != nil {
            let since = goneSince[m.id] ?? now
            goneSince[m.id] = since
            if now.timeIntervalSince(since) > 20 { pause(.closed(m)) }
        }
    }

    /// app / Mac 重启后窗口会换新的 CGWindowID，旧标记就失效了。
    /// 在同一个 app 新出现、还没被标记的窗口里找回来，备注跟着走：
    /// 标题完全相同 > 标题「 — 」后的项目名相同（VS Code / Cursor 等标题随当前文件变）> 该 app 只剩一个失效标记和一个候选窗口。
    /// 候选既有失效标记，也有因窗口关闭自动转成的待办（找回就恢复监控）
    private func reattach() {
        struct Lost { var mark: WinMark; var memo: Memo? }
        let lost = stale.map { Lost(mark: $0, memo: nil) }
            + Memos.shared.paused.compactMap { m in m.paused?.closed == true ? m.paused?.window.map { Lost(mark: $0, memo: m) } : nil }
        guard !lost.isEmpty else { return }
        let marked = Set(marks.windows.map(\.id))
        var free = windows.filter { !marked.contains($0.id) && $0.bundle != nil && $0.bounds.width > 80 && $0.bounds.height > 60 }
        var moved = 0
        func take(_ l: Lost, _ match: (WinInfo) -> Bool) -> Bool {
            let hits = free.filter { $0.bundle == l.mark.bundle && match($0) }
            guard hits.count == 1, let w = hits.first else { return false }
            var m = l.mark
            m.id = w.id
            if !w.title.isEmpty { m.title = w.title }
            if let memo = l.memo {
                Memos.shared.delete(memo.id)
                if memo.text != memo.paused?.label { m.note = memo.text }
                marks.windows.append(m)
            } else if let i = marks.windows.firstIndex(where: { $0.id == l.mark.id }) {
                marks.windows[i] = m
            } else {
                return false
            }
            goneSince[l.mark.id] = nil
            free.removeAll { $0.id == w.id }
            moved += 1
            return true
        }
        func project(_ t: String) -> String? {
            let p = t.components(separatedBy: " — ")
            return p.count > 1 ? p.last!.trimmingCharacters(in: .whitespaces) : nil
        }
        var left: [Lost] = []
        for l in lost where l.mark.bundle != nil {
            let t = l.mark.title
            if !t.isEmpty, take(l, { $0.title == t }) { continue }
            if let p = project(t), take(l, { project($0.title) == p }) { continue }
            left.append(l)
        }
        for l in left where left.filter({ $0.mark.bundle == l.mark.bundle }).count == 1 {
            _ = take(l) { _ in true }
        }
        if moved > 0 { save() }
    }

    /// 常驻采样循环，启动时开一次。
    /// 窗口墙在看：按设置的间隔截清晰缩略图；没在看：按后台间隔截小图，只用来统计画面静止了多久
    func startWatching() {
        guard watcher == nil else { return }
        watcher = Task { @MainActor in
            while !Task.isCancelled {
                refresh()
                let mon = monitored
                let ids = Set(mon.map(\.id))
                // Procman 被隐藏或窗口被完全挡住时算没在看
                let shown = (liveRequested && NSApp.windows.contains { isMainWindow($0) && $0.occlusionState.contains(.visible) })
                    || remoteViewers > 0
                let big = shown && Prefs.thumbs
                if (big || Prefs.watch), screenOK {
                    let now = Date()
                    let due = mon.filter { (backoff[$0.id] ?? .distantPast) <= now }
                    let shots = await capture(due, maxEdge: big ? 900 : 240)
                    for (id, shot) in shots {
                        switch shot {
                        case .image(let img, let fp):
                            if big || thumbs[id] == nil { thumbs[id] = img }
                            backoff[id] = nil
                            lastSample[id] = now
                            // 截图尺寸切换时缩放结果略有差异，只换基准不算变化
                            if let old = prints[id] {
                                if old.big == big && changed(old.fp, fp) { lastChange[id] = now }
                            } else if lastChange[id] == nil {
                                lastChange[id] = now
                            }
                            prints[id] = (fp, big)
                        case .failed:
                            backoff[id] = now.addingTimeInterval(10)
                        }
                    }
                    if debugLog { print("capture big=\(big) due=\(due.count) shots=\(shots.count)"); fflush(stdout) }
                }
                if thumbs.keys.contains(where: { !ids.contains($0) }) { thumbs = thumbs.filter { ids.contains($0.key) } }
                prints = prints.filter { ids.contains($0.key) }
                // 分小段睡，窗口墙一打开就能立刻截一轮
                let interval = shown ? Prefs.interval : Prefs.watchInterval
                let until = Date().addingTimeInterval(interval)
                kick = false
                while Date() < until && !kick && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
            }
        }
    }

    func startLive() { liveRequested = true; kick = true }

    func stopLive() { liveRequested = false }

    /// 画面静止了多少秒；nil = 还没采样过或最近采样不到（别把截图失败当成静止）
    func stillFor(_ id: CGWindowID, now: Date = Date()) -> TimeInterval? {
        guard let c = lastChange[id], let s = lastSample[id],
              now.timeIntervalSince(s) < max(60, Prefs.watchInterval * 3) else { return nil }
        return now.timeIntervalSince(c)
    }

}
