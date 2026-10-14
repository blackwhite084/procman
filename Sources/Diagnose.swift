import AppKit
import ApplicationServices

/// Procman --diagnose：以 Procman 自己的权限检查窗口墙的两条链路（AX 定位、截图），写到 ~/.procman/diagnose.txt。
/// 要用 open -n 启动，权限才按 Procman 算；直接在终端里跑二进制，权限算的是终端
@MainActor
func runDiagnose() async {
    var out = "Procman 诊断 \(Date())\n"
    out += "辅助功能 AXIsProcessTrusted = \(AXIsProcessTrusted())\n"
    out += "屏幕录制 CGPreflightScreenCaptureAccess = \(CGPreflightScreenCaptureAccess())\n"
    out += "SkyLight 跨桌面跳转接口可用 = \(skylightAvailable)\n\n"
    let home = URL(fileURLWithPath: ("~/.procman/marks.json" as NSString).expandingTildeInPath)
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let marks = (try? Data(contentsOf: home)).flatMap { try? dec.decode(Marks.self, from: $0) } ?? Marks()
    let all = listWindows()
    let targets = all.filter { w in
        marks.windows.contains { $0.id == w.id } || marks.apps.contains { $0.bundle == w.bundle }
    }
    out += "窗口总数 \(all.count)，监控中 \(targets.count)\n"
    for w in targets {
        out += "\n[\(w.id)] \(w.app) — \(w.title)\n  CG bounds=\(w.bounds) onScreen=\(w.onScreen)\n"
        let m = axMatch(w)
        out += "  AX kAXWindows err=\(m.error.rawValue) count=\(m.windows.count) 匹配方式=\(m.by)\n"
        for e in m.windows { out += "    - \(axDescribe(e))\n" }
        let t0 = Date()
        let shot = await capture([w.id], maxEdge: 600)[w.id]
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        switch shot {
        case .image(let img): out += "  截图 成功 \(Int(img.size.width))×\(Int(img.size.height)) \(ms)ms\n"
        case .failed: out += "  截图 失败/超时 \(ms)ms\n"
        case nil: out += "  截图 ScreenCaptureKit 列表里没有这个窗口 \(ms)ms\n"
        }
    }
    try? out.write(to: home.deletingLastPathComponent().appendingPathComponent("diagnose.txt"), atomically: true, encoding: .utf8)
}
