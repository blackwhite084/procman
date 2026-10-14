import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 全局快捷键

enum HotKeyAction: String, CaseIterable, Identifiable {
    case wall, markWindow, markApp
    var id: String { rawValue }

    var name: String {
        switch self {
        case .wall: "呼出 / 隐藏 Procman"
        case .markWindow: "标记 / 取消当前窗口"
        case .markApp: "标记 / 取消当前 app"
        }
    }

    var defaultCombo: Combo {
        switch self {
        case .wall: Combo(key: kVK_ANSI_W, mods: controlKey | optionKey, char: "W")
        case .markWindow: Combo(key: kVK_ANSI_M, mods: controlKey | optionKey, char: "M")
        case .markApp: Combo(key: kVK_ANSI_M, mods: controlKey | optionKey | shiftKey, char: "M")
        }
    }

    @MainActor func perform() {
        switch self {
        case .wall: WallActions.toggle()
        case .markWindow: Wall.shared.toggleFrontmostWindow()
        case .markApp: Wall.shared.toggleFrontmostApp()
        }
    }
}

/// key 是虚拟键码，mods 是 Carbon 修饰键掩码，char 只用于显示
struct Combo: Codable, Equatable {
    var key: Int
    var mods: Int
    var char: String

    var display: String {
        var s = ""
        if mods & controlKey != 0 { s += "⌃" }
        if mods & optionKey != 0 { s += "⌥" }
        if mods & shiftKey != 0 { s += "⇧" }
        if mods & cmdKey != 0 { s += "⌘" }
        return s + char
    }

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    private static let fKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                                          kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]

    /// 从录制到的按键构造；没有修饰键的普通键会抢走正常输入，不接受（F1–F12 除外）
    init?(event e: NSEvent) {
        let f = e.modifierFlags
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        let code = Int(e.keyCode)
        guard m & ~shiftKey != 0 || Self.fKeys.contains(code) else { return nil }
        // 按住 ⌥ 时 characters 会变成 ∑ 之类，用不带修饰的字符显示
        let ch = Self.special[code] ?? e.charactersIgnoringModifiers?.uppercased() ?? "?"
        self.init(key: code, mods: m, char: ch)
    }

    init(key: Int, mods: Int, char: String) {
        self.key = key
        self.mods = mods
        self.char = char
    }
}

/// Carbon RegisterEventHotKey：不需要「辅助功能」或「输入监控」权限，按键也不会漏给其他 app
@MainActor @Observable
final class HotKeys {
    static let shared = HotKeys()

    private(set) var combos: [HotKeyAction: Combo] = [:]   // 没有 = 已禁用
    private(set) var failed: Set<HotKeyAction> = []        // 注册失败，多半被别的 app 占用
    /// 正在录制哪个。录制期间暂停全部快捷键，否则按到已有组合会被 Carbon 先截走
    var recording: HotKeyAction? {
        didSet { recording == nil ? registerAll() : unregisterAll() }
    }

    @ObservationIgnored private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var installed = false
    private static let defaultsKey = "hotkeys"

    private init() {
        // 存的是 [动作: Combo]，key == -1 表示用户清除了；没存过的用默认值
        let saved = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: Combo].self, from: $0) } ?? [:]
        for a in HotKeyAction.allCases {
            let c = saved[a.rawValue] ?? a.defaultCombo
            if c.key >= 0 { combos[a] = c }
        }
    }

    func display(_ a: HotKeyAction) -> String { combos[a]?.display ?? "未设置" }

    /// nil = 禁用。和其他动作重复时，把对方的清掉
    func set(_ a: HotKeyAction, _ c: Combo?) {
        if let c { for (o, oc) in combos where o != a && oc.key == c.key && oc.mods == c.mods { combos[o] = nil } }
        combos[a] = c
        let dict = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map {
            ($0.rawValue, combos[$0] ?? Combo(key: -1, mods: 0, char: ""))
        })
        UserDefaults.standard.set(try? JSONEncoder().encode(dict), forKey: Self.defaultsKey)
        if recording == nil { registerAll() }
    }

    func registerAll() {
        unregisterAll()
        installHandler()
        var bad = Set<HotKeyAction>()
        for (i, a) in HotKeyAction.allCases.enumerated() {
            guard let c = combos[a] else { continue }
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(UInt32(c.key), UInt32(c.mods),
                                         EventHotKeyID(signature: OSType(0x50524D4E), id: UInt32(i)),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs[a] = ref } else { bad.insert(a) }
        }
        if bad != failed { failed = bad }
    }

    private func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let i = Int(hk.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyAction.allCases[safe: i]?.perform() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// 点一下进入录制：按新组合保存，esc 取消，delete 清除
struct HotKeyRecorder: View {
    let action: HotKeyAction
    @State private var monitor: Any?

    var body: some View {
        let hk = HotKeys.shared
        let recording = hk.recording == action
        HStack(spacing: 6) {
            if hk.failed.contains(action) {
                Text("注册失败，可能被其他 app 占用").font(.caption).foregroundStyle(.red)
            }
            Button(recording ? "按下快捷键…" : hk.display(action)) { recording ? stop() : start() }
                .font(.body.monospaced())
                .foregroundStyle(recording ? Color.accentColor : hk.combos[action] == nil ? .secondary : .primary)
                .frame(minWidth: 110)
                .help(recording ? "esc 取消 · delete 清除" : "点击后按下新的快捷键")
            Button {
                hk.set(action, action.defaultCombo)
            } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .help("恢复默认 \(action.defaultCombo.display)")
                .opacity(hk.combos[action] == action.defaultCombo ? 0 : 1)
                .disabled(hk.combos[action] == action.defaultCombo)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        stop()
        HotKeys.shared.recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                switch Int(e.keyCode) {
                case kVK_Escape: stop()
                case kVK_Delete, kVK_ForwardDelete: HotKeys.shared.set(action, nil); stop()
                default:
                    guard let c = Combo(event: e) else { NSSound.beep(); return nil }
                    HotKeys.shared.set(action, c)
                    stop()
                }
                return nil
            }
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if HotKeys.shared.recording == action { HotKeys.shared.recording = nil }
    }
}

// MARK: - HUD

/// 屏幕下方的短暂提示，不抢焦点，不挡鼠标
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var gen = 0

    static func show(_ text: String, icon: String = "checkmark.circle.fill") {
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel = p
            return p
        }()
        let host = NSHostingView(rootView: HUDView(text: text.count > 70 ? text.prefix(69) + "…" : text, icon: icon))
        let size = host.fittingSize
        p.contentView = host
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 110, width: size.width, height: size.height), display: true)
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        gen += 1
        let mine = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            MainActor.assumeIsolated {
                guard mine == gen else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated { if mine == gen { p.orderOut(nil) } }
                }
            }
        }
    }
}

private struct HUDView: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 15, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
    }
}
