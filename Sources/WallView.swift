import AppKit
import SwiftUI

// MARK: - 浮动面板

/// 无边框面板默认不能成为 key window，收不到键盘
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private func makePanel(level: NSWindow.Level) -> KeyPanel {
    let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = level
    p.isReleasedWhenClosed = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    return p
}

private func mouseScreen() -> NSScreen? {
    NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
}

/// 弹出前在用的 app。面板要收键盘就得激活 Procman，关掉时把焦点还回去
private func previousApp() -> NSRunningApplication? {
    let a = NSWorkspace.shared.frontmostApplication
    return a?.processIdentifier == getpid() ? nil : a
}

// MARK: - 窗口墙

@MainActor
final class WallWindow: NSObject, NSWindowDelegate {
    static let shared = WallWindow()
    private var panel: KeyPanel?
    private var prev: NSRunningApplication?
    private var monitor: Any?
    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide(restore: true) : show() }

    func show() {
        let p = panel ?? {
            let p = makePanel(level: .floating)
            p.delegate = self
            p.contentView = NSHostingView(rootView: WallView().environment(Wall.shared))
            panel = p
            return p
        }()
        if !isVisible { prev = previousApp() }
        if let vf = mouseScreen()?.visibleFrame {
            let w = vf.width * 0.8, h = vf.height * 0.82
            p.setFrame(NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h), display: false)
        }
        let wall = Wall.shared
        wall.refresh()
        wall.editing = nil
        wall.selection = wall.items.first?.id
        wall.startLive()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                MainActor.assumeIsolated { WallWindow.shared.key(e) ? nil : e }
            }
        }
    }

    func hide(restore: Bool) {
        guard let p = panel, p.isVisible else { return }
        Wall.shared.stopLive()
        Wall.shared.editing = nil
        p.orderOut(nil)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if restore { prev?.activate() }
        prev = nil
    }

    func jump(_ w: WinInfo) {
        hide(restore: false)
        if let msg = focusWindow(w) { HUD.show(msg, icon: "exclamationmark.triangle.fill") }
    }

    func manage() {
        hide(restore: false)
        Store.shared.openWindows?()
    }

    func windowDidResignKey(_ notification: Notification) { hide(restore: false) }

    /// 返回 true 表示按键已处理
    private func key(_ e: NSEvent) -> Bool {
        guard e.window === panel else { return false }
        let wall = Wall.shared
        if wall.editing != nil { return false }   // 正在编辑备注，键盘交给输入框
        let items = wall.items
        let cmd = e.modifierFlags.contains(.command)
        let i = items.firstIndex { $0.id == wall.selection }
        let cols = Wall.columns(items.count)
        func move(_ d: Int) {
            guard !items.isEmpty else { return }
            wall.selection = items[min(max((i ?? 0) + d, 0), items.count - 1)].id
        }
        switch Int(e.keyCode) {
        case 53: hide(restore: true)
        case 36, 76: if let i, case .live(let w) = items[i] { jump(w) }
        case 123: move(-1)
        case 124: move(1)
        case 125: move(cols)
        case 126: move(-cols)
        default:
            let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
            if cmd, ch == "d", let i { wall.remove(items[i]); wall.selection = wall.items[safe: i]?.id ?? wall.items.last?.id }
            else if cmd, ch == "e", let i { wall.editing = items[i].id }
            else if cmd, ch == "," { manage() }
            else if !cmd, let n = Int(ch), n >= 1, n <= min(9, items.count), case .live(let w) = items[n - 1] { jump(w) }
            else { return false }
        }
        return true
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// 墙上的一格：活着的窗口，或者已经关掉但写了备注的窗口（当待办留着）
enum WallItem: Identifiable {
    case live(WinInfo)
    case closed(WinMark)
    var id: CGWindowID {
        switch self {
        case .live(let w): w.id
        case .closed(let m): m.id
        }
    }
}

extension Wall {
    var items: [WallItem] {
        monitored.map(WallItem.live) + stale.filter { $0.note != nil }.map(WallItem.closed)
    }

    static func columns(_ n: Int) -> Int { n <= 1 ? 1 : n <= 4 ? 2 : n <= 9 ? 3 : 4 }

    func remove(_ item: WallItem) {
        switch item {
        case .live(let w): unmark(w)
        case .closed(let m): remove(id: m.id)
        }
    }
}

struct WallView: View {
    @Environment(Wall.self) private var wall

    var body: some View {
        let items = wall.items
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("窗口墙").font(.title2.weight(.semibold))
                Text("\(wall.monitored.count) 个窗口").foregroundStyle(.secondary)
                Spacer()
                PermissionWarnings()
                Button { WallWindow.shared.manage() } label: { Label("管理", systemImage: "slider.horizontal.3") }
                    .help("管理监控窗口 ⌘,")
            }
            if items.isEmpty {
                ContentUnavailableView {
                    Label("还没有监控的窗口", systemImage: "rectangle.on.rectangle.slash")
                } description: {
                    Text("切到想盯的窗口按 \(HotKeys.shared.display(.markWindow))，整个 app 按 \(HotKeys.shared.display(.markApp))，\n或者在「管理」里勾选。")
                } actions: {
                    Button("打开管理") { WallWindow.shared.manage() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WallGrid(items: items)
            }
            Text("↩ 跳转 · 1–9 快速跳转 · 方向键选择 · ⌘E 编辑备注（或点备注） · ⌘D 取消监控 · esc 关闭")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }
}

private struct PermissionWarnings: View {
    @Environment(Wall.self) private var wall
    var body: some View {
        if !wall.screenOK {
            Button { Permission.requestScreen() } label: {
                Label("缺屏幕录制权限，只显示图标", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.borderless).foregroundStyle(.orange)
            .help("系统设置 → 隐私与安全性 → 录屏与系统录音，勾上 Procman，然后在管理窗口点「重启 Procman」")
        }
        if !wall.axOK {
            Button { Permission.requestAccessibility() } label: {
                Label("缺辅助功能权限，无法精确跳转", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.borderless).foregroundStyle(.orange)
        }
    }
}

private struct WallGrid: View {
    let items: [WallItem]
    private let gap: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let cols = Wall.columns(items.count)
            let rows = Int(ceil(Double(items.count) / Double(cols)))
            let tileW = (geo.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            // 尽量一屏放下；放不下就保持最小高度、允许滚动
            let fit = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows) - 78
            let thumbH = max(140, min(tileW * 0.62, fit))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileW), spacing: gap), count: cols), spacing: gap) {
                    ForEach(Array(items.enumerated()), id: \.1.id) { i, item in
                        WallTile(item: item, index: i, thumbH: thumbH)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }
}

private struct WallTile: View {
    @Environment(Wall.self) private var wall
    let item: WallItem
    let index: Int
    let thumbH: CGFloat
    @State private var hover = false

    var body: some View {
        let selected = wall.selection == item.id
        VStack(alignment: .leading, spacing: 7) {
            thumbnail
                .frame(maxWidth: .infinity)
                .frame(height: thumbH)
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if index < 9 {
                        Text("\(index + 1)").font(.caption.weight(.bold).monospacedDigit())
                            .frame(width: 20, height: 20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .padding(6)
                    }
                }
            titleRow
            NoteRow(item: item, active: selected || hover)
        }
        .padding(9)
        .background(selected ? Color.accentColor.opacity(0.22) : hover ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hover = $0; if $0 && wall.editing == nil { wall.selection = item.id } }
        .onTapGesture { if case .live(let w) = item { WallWindow.shared.jump(w) } }
        .contextMenu { menu }
        .opacity(isClosed ? 0.75 : 1)
    }

    private var isClosed: Bool { if case .closed = item { true } else { false } }

    @ViewBuilder private var thumbnail: some View {
        switch item {
        case .live(let w):
            if let img = wall.thumbs[w.id] {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: wall.icon(w.pid)).resizable().frame(width: 72, height: 72)
            }
        case .closed:
            VStack(spacing: 6) {
                Image(systemName: "xmark.rectangle").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("窗口已关闭").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var titleRow: some View {
        HStack(spacing: 6) {
            switch item {
            case .live(let w):
                Image(nsImage: wall.icon(w.pid)).resizable().frame(width: 16, height: 16)
                Text(w.label).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !w.onScreen { Badge(text: "其他桌面 / 最小化") }
                if wall.via(w) == .app { Badge(text: "整个 app") }
            case .closed(let m):
                Text(m.title.isEmpty ? m.app : "\(m.app) — \(m.title)").font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        switch item {
        case .live(let w): w.title.isEmpty ? w.app : "\(w.app) — \(w.title)"
        case .closed(let m): "\(m.app) — \(m.title)（窗口已关闭，备注保留）"
        }
    }

    @ViewBuilder private var menu: some View {
        if case .live(let w) = item {
            Button("跳转") { WallWindow.shared.jump(w) }
            Divider()
        }
        Button("编辑备注") { wall.editing = item.id }
        Divider()
        switch item {
        case .live(let w):
            Button(wall.via(w) == .app ? "取消监控整个 \(w.app)" : "取消监控此窗口") { wall.unmark(w) }
            if wall.via(w) == .window, let b = w.bundle, !wall.appMarked(b) {
                Button("改为监控整个 \(w.app)") { wall.toggleApp(bundle: b, name: w.app) }
            }
        case .closed(let m):
            Button("删除（待办已完成）") { wall.remove(id: m.id) }
        }
    }
}

private struct NoteRow: View {
    @Environment(Wall.self) private var wall
    let item: WallItem
    let active: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var note: String? {
        switch item {
        case .live(let w): wall.note(w)
        case .closed(let m): m.note
        }
    }

    private var added: Date? {
        switch item {
        case .live(let w): wall.added(w)
        case .closed(let m): m.added
        }
    }

    var body: some View {
        Group {
            if wall.editing == item.id {
                TextField("备注…  回车保存，esc 取消", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { wall.editing = nil }
                    .onAppear { draft = note ?? ""; focused = true }
                    .onChange(of: focused) { _, f in if !f && wall.editing == item.id { commit() } }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let note {
                        Image(systemName: "note.text").font(.caption).foregroundStyle(.yellow)
                        Text(note).font(.callout).lineLimit(2).foregroundStyle(.primary)
                    } else {
                        Text(active ? "＋ 添加备注" : " ").font(.callout).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if let added { Text(ago(added)).font(.caption).foregroundStyle(.tertiary).fixedSize() }
                }
                .contentShape(Rectangle())
                .onTapGesture { wall.selection = item.id; wall.editing = item.id }
                .help("点击编辑备注")
            }
        }
        .frame(minHeight: 22, alignment: .top)
    }

    private func commit() {
        switch item {
        case .live(let w): wall.setNote(w, draft)
        case .closed(let m): wall.setNote(id: m.id, draft)
        }
        wall.editing = nil
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

private let agoFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.unitsStyle = .short
    return f
}()

func ago(_ d: Date) -> String {
    Date().timeIntervalSince(d) < 60 ? "刚刚" : agoFormatter.localizedString(for: d, relativeTo: Date())
}

// MARK: - 标记时的备注输入框

@MainActor
final class NotePrompt: NSObject, NSWindowDelegate {
    static let shared = NotePrompt()
    private var panel: KeyPanel?
    private var prev: NSRunningApplication?
    private var onSave: ((String) -> Void)?
    private var model = NoteModel()

    /// 标记成功后弹出，回车保存、esc 跳过，然后把焦点还给原窗口
    func ask(title: String, onSave: @escaping (String) -> Void) {
        finish(save: true, restore: false)   // 上一个还开着就先按保存处理
        let p = panel ?? {
            let p = makePanel(level: .modalPanel)
            p.delegate = self
            p.contentView = NSHostingView(rootView: NotePromptView(model: model))
            panel = p
            return p
        }()
        prev = previousApp()
        self.onSave = onSave
        model.title = title
        model.text = ""
        model.token += 1
        let w: CGFloat = 520, h: CGFloat = 112
        if let vf = mouseScreen()?.visibleFrame {
            p.setFrame(NSRect(x: vf.midX - w / 2, y: vf.minY + 110, width: w, height: h), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func finish(save: Bool, restore: Bool = true) {
        guard let p = panel, p.isVisible else { return }
        if save { onSave?(model.text) }
        onSave = nil
        p.orderOut(nil)
        if restore { prev?.activate() }
        prev = nil
    }

    // 点到别处：已经输入的内容别丢
    func windowDidResignKey(_ notification: Notification) { finish(save: true, restore: false) }
}

@Observable
final class NoteModel {
    var title = ""
    var text = ""
    var token = 0
}

private struct NotePromptView: View {
    @Bindable var model: NoteModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.title, systemImage: "eye").font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            TextField("备注（可选）：这个窗口在等什么 / 回来要做什么", text: $model.text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { NotePrompt.shared.finish(save: true) }
                .onExitCommand { NotePrompt.shared.finish(save: false) }
            Text("↩ 保存 · esc 跳过 · 之后可在窗口墙（\(HotKeys.shared.display(.wall))）里点备注修改")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
        .onChange(of: model.token, initial: true) { focused = true }
    }
}

// MARK: - 管理窗口

struct WindowsView: View {
    @Environment(Wall.self) private var wall
    @AppStorage("wallThumbs") private var thumbsOn = true
    @State private var query = ""

    private struct Group: Identifiable {
        let id: String
        let app: String
        let bundle: String?
        let pid: pid_t
        var windows: [WinInfo]
    }

    private var groups: [Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Group] = []
        for w in wall.windows {
            if !q.isEmpty, !w.app.lowercased().contains(q), !w.title.lowercased().contains(q),
               !(wall.note(w)?.lowercased().contains(q) ?? false) { continue }
            let key = w.bundle ?? w.app
            if let i = out.firstIndex(where: { $0.id == key }) { out[i].windows.append(w) }
            else { out.append(Group(id: key, app: w.app, bundle: w.bundle, pid: w.pid, windows: [w])) }
        }
        // 有监控的 app 排前面
        return out.sorted { a, b in
            let ma = a.windows.contains { wall.via($0) != nil }, mb = b.windows.contains { wall.via($0) != nil }
            return ma != mb ? ma : a.app.localizedStandardCompare(b.app) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section("快捷键与权限") { SetupRows() }

            if !wall.stale.isEmpty {
                Section {
                    ForEach(wall.stale, id: \.id) { m in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.title.isEmpty ? m.app : "\(m.app) — \(m.title)").lineLimit(1)
                                NoteField(note: m.note) { wall.setNote(id: m.id, $0) }
                            }
                            Spacer()
                            Button("删除") { wall.remove(id: m.id) }.controlSize(.small)
                        }
                    }
                } header: {
                    HStack {
                        Text("已关闭的窗口 · 有备注的会留在窗口墙上")
                        Spacer()
                        Button("清理无备注的") { wall.prune(keepNotes: true) }.buttonStyle(.borderless)
                        Button("全部清理") { wall.prune(keepNotes: false) }.buttonStyle(.borderless)
                    }
                }
            }

            ForEach(groups) { g in
                Section {
                    if let b = g.bundle, let am = wall.appMark(b) {
                        NoteField(note: am.note, prompt: "整个 app 的备注…") { wall.setAppNote(b, $0) }
                    }
                    ForEach(g.windows) { w in WindowRow(w: w) }
                } header: {
                    HStack(spacing: 6) {
                        Image(nsImage: wall.icon(g.pid)).resizable().frame(width: 16, height: 16)
                        Text(g.app)
                        Spacer()
                        if let b = g.bundle {
                            Toggle("监控整个 app", isOn: Binding(get: { wall.appMarked(b) },
                                                              set: { _ in wall.toggleApp(bundle: b, name: g.app) }))
                                .toggleStyle(.checkbox).controlSize(.small)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "app / 窗口标题 / 备注")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $thumbsOn) { Label("实时缩略图", systemImage: "photo") }
                    .help("关掉则窗口墙只显示 app 图标")
                Button { WallWindow.shared.show() } label: { Label("打开窗口墙", systemImage: "square.grid.2x2") }
                    .help("打开窗口墙 \(HotKeys.shared.display(.wall))")
            }
        }
        .task {
            while !Task.isCancelled {
                wall.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        .onDisappear(perform: updateActivationPolicy)
    }
}

private struct WindowRow: View {
    @Environment(Wall.self) private var wall
    let w: WinInfo

    var body: some View {
        let via = wall.via(w)
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { via != nil }, set: { _ in wall.toggle(w) }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(via == .app)
                .help(via == .app ? "整个 app 已在监控中" : "监控这个窗口")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(w.title.isEmpty ? "（无标题）" : w.title).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(w.title.isEmpty ? .secondary : .primary)
                    if !w.onScreen { Text("不在当前桌面").font(.caption).foregroundStyle(.tertiary) }
                }
                if via == .window {
                    NoteField(note: wall.note(w)) { wall.setNote(id: w.id, $0) }
                }
            }
            Spacer()
            Text("\(Int(w.bounds.width))×\(Int(w.bounds.height))").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Button { focusWindow(w) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless).help("跳到这个窗口")
        }
    }
}

/// 失焦或回车时保存
private struct NoteField: View {
    let note: String?
    var prompt = "备注…"
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1...3)
            .focused($focused)
            .onSubmit { onCommit(text); focused = false }
            .onChange(of: focused) { _, f in if !f, text != (note ?? "") { onCommit(text) } }
            .onAppear { text = note ?? "" }
            .onChange(of: note) { _, n in if !focused { text = n ?? "" } }
    }
}

private struct SetupRows: View {
    @Environment(Wall.self) private var wall

    var body: some View {
        ForEach(HotKeyAction.allCases) { a in
            LabeledContent(a.name) { HotKeyRecorder(action: a) }
        }
        LabeledContent("屏幕录制（缩略图、窗口标题）") {
            permission(wall.screenOK, Permission.requestScreen)
        }
        LabeledContent("辅助功能（精确跳到指定窗口）") {
            permission(wall.axOK, Permission.requestAccessibility)
        }
        if !wall.screenOK || !wall.axOK {
            HStack {
                Text("在系统设置里勾上 Procman 后需要重启 Procman 才生效（服务不受影响）")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重启 Procman") { relaunch() }
            }
        }
    }

    @ViewBuilder func permission(_ ok: Bool, _ request: @escaping () -> Void) -> some View {
        if ok {
            Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Button("去授权…", action: request)
        }
    }
}
