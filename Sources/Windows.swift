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

/// 跳到指定窗口。匹配顺序：窗口 ID → 几何位置（容差 6 点）→ 该 app 只有一个窗口；
/// 都没命中就只激活 app。成功返回 nil，否则返回给用户看的原因
@discardableResult
func focusWindow(_ w: WinInfo) -> String? {
    guard let app = NSRunningApplication(processIdentifier: w.pid) else { return "\(w.app) 已经退出了" }
    var target: AXUIElement?
    var raw: CFTypeRef?
    if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(w.pid), kAXWindowsAttribute as CFString, &raw) == .success,
       let wins = raw as? [AXUIElement] {
        let near = { (r: CGRect) in
            abs(r.minX - w.bounds.minX) <= 6 && abs(r.minY - w.bounds.minY) <= 6
                && abs(r.width - w.bounds.width) <= 6 && abs(r.height - w.bounds.height) <= 6
        }
        target = wins.first { axWindowID($0) == w.id }
            ?? wins.first { axFrame($0).map(near) ?? false }
            ?? (wins.count == 1 ? wins[0] : nil)
    }
    if let t = target {
        AXUIElementSetAttributeValue(t, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        // 先在 app 内部把它提到最前再激活 app，否则多窗口 app 会切到它自己记的「上一个」窗口
        AXUIElementSetAttributeValue(t, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(t, kAXRaiseAction as CFString)
    }
    if app.isHidden { app.unhide() }
    app.activate()
    if target != nil { return nil }
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

/// 截一批窗口。截不到的（被关掉、其他桌面空间没有绘制缓冲）不出现在结果里，调用方保留旧图
private func capture(_ ids: Set<CGWindowID>, maxEdge: CGFloat) async -> [CGWindowID: NSImage] {
    guard !ids.isEmpty,
          let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return [:] }
    var out: [CGWindowID: NSImage] = [:]
    for w in content.windows where ids.contains(w.windowID) {
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
        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
            out[w.windowID] = NSImage(cgImage: img, size: r.size)
        }
    }
    return out
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

    @ObservationIgnored private var live: Task<Void, Never>?
    @ObservationIgnored private var icons: [pid_t: NSImage] = [:]
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
        if list != windows { windows = list }
        screenOK = Permission.screen
        axOK = Permission.accessibility
    }

    /// 窗口墙显示期间每秒刷新窗口列表并重截缩略图
    func startLive() {
        live?.cancel()
        live = Task { @MainActor in
            while !Task.isCancelled {
                refresh()
                let ids = Set(monitored.map(\.id))
                // Procman 被隐藏或窗口被完全挡住时不截图
                let shown = NSApp.windows.contains { isMainWindow($0) && $0.occlusionState.contains(.visible) }
                if shown, UserDefaults.standard.object(forKey: "wallThumbs") as? Bool ?? true, screenOK {
                    let shots = await capture(ids, maxEdge: 900)
                    if Task.isCancelled { break }
                    for (id, img) in shots { thumbs[id] = img }
                }
                if thumbs.keys.contains(where: { !ids.contains($0) }) { thumbs = thumbs.filter { ids.contains($0.key) } }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopLive() { live?.cancel(); live = nil }
}
