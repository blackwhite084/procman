import AppKit
import SwiftUI

/// 增量读取日志文件，直接写入 NSTextView（不经过 SwiftUI 状态，大日志也不卡）
@MainActor
final class LogController {
    weak var textView: NSTextView?
    var follow = true
    private var path: String?
    private var offset: UInt64 = 0
    private var carry = Data()
    private var tailRaw = ""
    private var lastLineStart = 0
    private var timer: Timer?

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let ansi = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[()][A-Za-z0-9]|\u{1B}[=>]")

    func attach(_ path: String) {
        self.path = path
        reset()
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func detach() { timer?.invalidate(); timer = nil }

    func reset() {
        textView?.string = ""
        offset = 0; carry = Data(); tailRaw = ""; lastLineStart = 0
    }

    func poll() {
        guard let path, textView != nil, let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { reset() }  // 被清空或轮转
        if offset == 0 && size > 256 << 10 { offset = size - (256 << 10) }
        guard size > offset else { return }
        try? fh.seek(toOffset: offset)
        let data = fh.readData(ofLength: Int(min(size - offset, 1 << 20)))
        offset += UInt64(data.count)
        var bytes = carry + data
        let cut = utf8Boundary(bytes)
        carry = bytes.subdata(in: cut..<bytes.count)
        bytes = bytes.subdata(in: 0..<cut)
        append(String(decoding: bytes, as: UTF8.self))
    }

    private func append(_ chunk: String) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        var s = tailRaw + chunk
        if s.contains("\u{1B}") {
            s = Self.ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        var lines = s.components(separatedBy: "\n")
        let last = lines.removeLast()
        let out = NSMutableAttributedString()
        for l in lines { out.append(styled(clean(l) + "\n")) }
        let lastClean = clean(last)
        out.append(styled(lastClean))

        ts.beginEditing()
        // 未换行的最后一行（如 tqdm 进度条的 \r）整体替换
        ts.replaceCharacters(in: NSRange(location: lastLineStart, length: ts.length - lastLineStart), with: out)
        lastLineStart = ts.length - (lastClean as NSString).length
        if ts.length > 800_000 {
            let str = ts.string as NSString
            var cut = ts.length - 600_000
            let nl = str.range(of: "\n", range: NSRange(location: cut, length: str.length - cut))
            if nl.location != NSNotFound { cut = nl.location + 1 }
            ts.deleteCharacters(in: NSRange(location: 0, length: cut))
            lastLineStart -= cut
        }
        ts.endEditing()
        tailRaw = String(last.suffix(20_000))
        if follow { tv.scrollToEndOfDocument(nil) }
    }

    private func clean(_ line: String) -> String {
        var l = Substring(line)
        if l.hasSuffix("\r") { l = l.dropLast() }
        if let i = l.lastIndex(of: "\r") { l = l[l.index(after: i)...] }
        return String(l)
    }

    private func styled(_ line: String) -> NSAttributedString {
        let color: NSColor
        if line.hasPrefix("=====") {
            color = NSColor(red: 0.45, green: 0.68, blue: 1, alpha: 1)
        } else if line.hasPrefix("$ ") && line.count < 2000 {
            color = NSColor(white: 0.6, alpha: 1)
        } else {
            let low = line.prefix(400).lowercased()
            if low.contains("error") || low.contains("traceback") || low.contains("exception") || low.contains("failed") {
                color = NSColor(red: 1, green: 0.45, blue: 0.42, alpha: 1)
            } else if low.contains("warn") {
                color = NSColor(red: 1, green: 0.75, blue: 0.35, alpha: 1)
            } else {
                color = NSColor(white: 0.86, alpha: 1)
            }
        }
        return NSAttributedString(string: line, attributes: [.font: Self.font, .foregroundColor: color])
    }

    /// 末尾可能截断了多字节 UTF-8 字符，留到下次再解码
    private func utf8Boundary(_ d: Data) -> Int {
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
}

struct LogView: NSViewRepresentable {
    let controller: LogController

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(red: 0.075, green: 0.08, blue: 0.095, alpha: 1)
        tv.insertionPointColor = .white
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sv.drawsBackground = true
        sv.backgroundColor = tv.backgroundColor
        sv.scrollerKnobStyle = .light
        controller.textView = tv
        return sv
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
