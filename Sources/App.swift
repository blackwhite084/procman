import AppKit
import SwiftUI

@main
struct ProcmanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store.shared

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
            renderIconset(to: CommandLine.arguments[i + 1])
            exit(0)
        }
    }

    var body: some Scene {
        Window("Procman", id: "main") {
            MainView().environment(store)
        }
        .defaultSize(width: 1040, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(before: .toolbar) {
                Button("窗口墙") { Store.shared.tab = .wall }.keyboardShortcut("1")
                Button("服务") { Store.shared.tab = .services }.keyboardShortcut("2")
                Divider()
            }
        }

        Window("端口占用", id: "ports") {
            PortsView().environment(store)
        }
        .defaultSize(width: 900, height: 520)
        .defaultLaunchBehavior(.suppressed)

        Window("窗口监控", id: "windows") {
            WindowsView().environment(Wall.shared)
        }
        .defaultSize(width: 720, height: 640)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView().environment(store).environment(Wall.shared)
        }

        MenuBarExtra {
            MenuContent().environment(store)
        } label: {
            MenuLabel().environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(Store.background ? .accessory : .regular)
        NSApp.applicationIconImage = appIcon(size: 512)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { HotKeys.shared.registerAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { Store.shared.openMain?() } }
        return true
    }
}

// MARK: - 图标（代码绘制，构建时导出成 icns）

func appIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        let inset = r.width * 0.1
        let rect = r.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        NSGradient(colors: [NSColor(red: 0.16, green: 0.2, blue: 0.32, alpha: 1),
                            NSColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1)])!.draw(in: path, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.42, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(red: 0.4, green: 0.9, blue: 0.6, alpha: 1)]))
        if let sym = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
}

func renderIconset(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: px, height: px)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            appIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
        }
    }
}
