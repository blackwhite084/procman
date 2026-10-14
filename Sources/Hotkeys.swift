import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 全局快捷键

/// Carbon RegisterEventHotKey：不需要「辅助功能」或「输入监控」权限，按键也不会被吞给其他 app
@MainActor
enum HotKeys {
    struct Def { let name: String; let key: Int; let mods: Int; let display: String }

    static let wall = Def(name: "打开窗口墙", key: kVK_ANSI_W, mods: controlKey | optionKey, display: "⌃⌥W")
    static let markWindow = Def(name: "标记 / 取消当前窗口", key: kVK_ANSI_M, mods: controlKey | optionKey, display: "⌃⌥M")
    static let markApp = Def(name: "标记 / 取消当前 app", key: kVK_ANSI_M, mods: controlKey | optionKey | shiftKey, display: "⌃⌥⇧M")
    static let all = [wall, markWindow, markApp]

    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false

    /// 返回注册失败（多半是被别的 app 占用）的快捷键
    static func setup() -> [String] {
        let pairs: [(Def, () -> Void)] = [
            (wall, { WallWindow.shared.toggle() }),
            (markWindow, { Wall.shared.toggleFrontmostWindow() }),
            (markApp, { Wall.shared.toggleFrontmostApp() }),
        ]
        return pairs.compactMap { register($0.0, $0.1) ? nil : $0.0.display }
    }

    private static func register(_ d: Def, _ action: @escaping () -> Void) -> Bool {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.actions[id]?() } }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(d.key), UInt32(d.mods), EventHotKeyID(signature: OSType(0x50524D4E), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        guard st == noErr else { return false }
        actions[id] = action
        return true
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
