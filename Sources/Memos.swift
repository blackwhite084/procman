import AppKit
import Observation
import SwiftUI

// MARK: - 待办（不绑定窗口的零散备注）

struct Memo: Codable, Identifiable, Hashable {
    var id = String(UUID().uuidString.prefix(8)).lowercased()
    var text: String
    var added = Date()
    var done: Date?
    var paused: Paused?   // 从窗口墙暂停下来的监控，恢复时还原
}

/// 暂停监控时摘下来的标记（单个窗口或整个 app 二选一）
struct Paused: Codable, Hashable {
    var window: WinMark?
    var app: AppMark?
    var label: String     // 转成待办时的默认文字，用来判断恢复时要不要把改过的文字写回备注
    var closed: Bool?     // true = 窗口关闭自动转的，窗口重开时自动恢复；nil = 手动暂停
}

/// 存在 ~/.procman/memos.json，每次改动立即写盘
@MainActor @Observable
final class Memos {
    static let shared = Memos()
    private(set) var items: [Memo] = []
    var focusInput = 0   // 加一 = 让待办栏的输入框获得焦点

    private var url: URL { Store.shared.home.appendingPathComponent("memos.json") }

    private init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let m = try? dec.decode([Memo].self, from: d) { items = m }
    }

    var open: [Memo] { items.filter { $0.done == nil && $0.paused == nil } }
    var paused: [Memo] { items.filter { $0.done == nil && $0.paused != nil } }
    var done: [Memo] { items.filter { $0.done != nil }.sorted { $0.done! > $1.done! } }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.insert(Memo(text: t), at: 0)
        save()
    }

    func addPaused(_ text: String, _ p: Paused) {
        items.insert(Memo(text: text, paused: p), at: 0)
        save()
    }

    /// 恢复监控：标记放回窗口墙，待办移除
    func resume(_ id: String) {
        guard let m = items.first(where: { $0.id == id }), let p = m.paused else { return }
        Wall.shared.restore(p, text: m.text)
        delete(id)
    }

    /// 改成空 = 删除
    func edit(_ id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if t.isEmpty { items.remove(at: i) } else { items[i].text = t }
        save()
    }

    func toggle(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done = items[i].done == nil ? Date() : nil
        save()
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func clearDone() {
        items.removeAll { $0.done != nil }
        save()
    }

    /// 只在未完成的条目里拖动排序
    func move(from: IndexSet, to: Int) {
        var o = open
        o.move(fromOffsets: from, toOffset: to)
        let ids = Set(o.map(\.id))
        items = o + items.filter { !ids.contains($0.id) }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(items).write(to: url, options: .atomic)
    }
}

// MARK: - 窗口墙右侧的待办栏

struct MemoColumn: View {
    @Environment(Memos.self) private var memos
    @State private var input = ""
    @State private var showDone = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("待办", systemImage: "checklist").font(.headline)
                Spacer()
                if !memos.open.isEmpty { Text("\(memos.open.count)").foregroundStyle(.secondary).monospacedDigit() }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            TextField("记一件事…  ↩ 添加", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { memos.add(input); input = "" }
                .onExitCommand { input = ""; inputFocused = false }
                .padding(.horizontal, 12).padding(.bottom, 6)

            List {
                ForEach(memos.open) { m in MemoRow(memo: m) }
                    .onMove { memos.move(from: $0, to: $1) }
                if memos.open.isEmpty {
                    Text("零散的事记在这里，做完勾掉").font(.callout).foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                }
                if !memos.paused.isEmpty {
                    Section {
                        ForEach(memos.paused) { m in MemoRow(memo: m) }
                    } header: {
                        Label("已暂停的窗口 \(memos.paused.count)", systemImage: "pause.circle").font(.caption)
                    }
                }
                if !memos.done.isEmpty {
                    Section {
                        if showDone { ForEach(memos.done) { m in MemoRow(memo: m) } }
                    } header: {
                        HStack {
                            Button { showDone.toggle() } label: {
                                Label("已完成 \(memos.done.count)", systemImage: showDone ? "chevron.down" : "chevron.right")
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            if showDone { Button("清空") { memos.clearDone() }.buttonStyle(.borderless) }
                        }
                        .font(.caption)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .onChange(of: memos.focusInput) { inputFocused = true }
    }
}

private struct MemoRow: View {
    @Environment(Memos.self) private var memos
    let memo: Memo
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        let done = memo.done != nil
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { memos.toggle(memo.id) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(done ? "标为未完成" : "完成")
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, f in if !f && editing { commit() } }
                        .onAppear { draft = memo.text; focused = true }
                } else {
                    Text(memo.text)
                        .strikethrough(done)
                        .foregroundStyle(done ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = true }
                        .help("点击编辑")
                }
                Text(pausedNote + ago(memo.done ?? memo.added)).font(.caption2).foregroundStyle(.tertiary)
            }
            if memo.paused != nil && memo.done == nil {
                Button { memos.resume(memo.id) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless).foregroundStyle(Color.accentColor).help("恢复监控，放回窗口墙")
            }
            if hover && !editing {
                Button { memos.delete(memo.id) } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除")
            }
        }
        .padding(.vertical, 2)
        .onHover { hover = $0 }
        .contextMenu {
            Button("编辑") { editing = true }
            Button(done ? "标为未完成" : "完成") { memos.toggle(memo.id) }
            if memo.paused != nil && !done { Button("恢复监控") { memos.resume(memo.id) } }
            Button("复制") { copy(memo.text) }
            Divider()
            Button("删除", role: .destructive) { memos.delete(memo.id) }
        }
    }

    /// 已暂停的条目注明来源窗口，文字被改成备注后也知道是哪个窗口
    private var pausedNote: String {
        guard let p = memo.paused else { return "" }
        let what = p.closed == true ? "窗口已关闭，重开后自动恢复" : "已暂停"
        return memo.text == p.label ? "\(what) · " : "\(p.label) · \(what) · "
    }

    private func commit() {
        memos.edit(memo.id, draft)
        editing = false
    }
}
