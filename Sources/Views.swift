import AppKit
import SwiftUI

// MARK: - 主窗口

struct MainView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage("selected") private var selected: String?
    @State private var editing: Service?

    var body: some View {
        NavigationSplitView {
            Sidebar(selected: $selected, editing: $editing)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let id = selected, let s = store.service(id) {
                DetailView(service: s, editing: $editing).id(s.id)
            } else {
                EmptyState(editing: $editing)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openWindow(id: "ports") } label: { Label("端口占用", systemImage: "network") }
                    .help("查看所有正在监听的端口 ⇧⌘P")
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button { editing = Service() } label: { Label("新建", systemImage: "plus") }
                    .help("新建服务 ⌘N")
                    .keyboardShortcut("n")
            }
        }
        .sheet(item: $editing) { s in
            EditSheet(draft: s, isNew: store.service(s.id) == nil) { saved in
                store.upsert(saved)
                selected = saved.id
            }
        }
        .onChange(of: store.pendingNew) { _, s in
            if let s { editing = s; store.pendingNew = nil }
        }
        .alert("端口 \(store.conflict?.port ?? 0) 已被占用", isPresented: Binding(
            get: { store.conflict != nil }, set: { if !$0 { store.conflict = nil } }), presenting: store.conflict) { c in
            if !c.owners.isEmpty {
                Button("结束占用进程并启动", role: .destructive) { store.killOwnersThenStart(c) }
            }
            Button("仍然启动") { store.tryStart(c.serviceID, interactive: false) }
            Button("取消", role: .cancel) {}
        } message: { c in
            Text(c.owners.isEmpty
                 ? "无法查看占用者（可能是 root / 系统进程），可在终端用 sudo lsof -iTCP:\(c.port) 查看。"
                 : c.owners.map { "\($0.command)  PID \($0.pid)  \($0.user)\n\($0.args.prefix(160))" }.joined(separator: "\n\n"))
        }
        .alert("出错了", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("好") {}
        } message: { Text(store.lastError ?? "") }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear(perform: updateActivationPolicy)
    }
}

struct EmptyState: View {
    @Environment(Store.self) private var store
    @Binding var editing: Service?
    var body: some View {
        ContentUnavailableView {
            Label(store.services.isEmpty ? "还没有服务" : "选择一个服务", systemImage: "shippingbox")
        } description: {
            Text(store.services.isEmpty ? "添加启动目录和命令，一键启停、查看输出" : "在左侧选择服务查看详情和输出")
        } actions: {
            if store.services.isEmpty { Button("新建服务") { editing = Service() }.buttonStyle(.borderedProminent) }
        }
    }
}

// MARK: - 侧栏

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Binding var selected: String?
    @Binding var editing: Service?
    @State private var confirmDelete: Service?

    var body: some View {
        List(selection: $selected) {
            Section {
                ForEach(store.services) { s in
                    ServiceRow(service: s).tag(s.id)
                        .contextMenu { menu(s) }
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                Text(store.services.isEmpty ? "服务" : "服务 · \(store.runningCount)/\(store.services.count) 运行中")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Toggle(isOn: Binding(get: { store.loginItem }, set: { store.setLoginItem($0) })) {
                Label("登录时启动 Procman", systemImage: "power").font(.callout)
            }
            .toggleStyle(.switch).controlSize(.mini)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .help("开机登录后自动在后台运行，并拉起勾选了「自动启动」的服务")
        }
        .confirmationDialog("删除「\(confirmDelete?.name ?? "")」？", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let s = confirmDelete { store.delete(s.id); if selected == s.id { selected = nil } }
            }
        } message: { Text("运行中的进程会先被停止，日志一并删除。") }
    }

    @ViewBuilder func menu(_ s: Service) -> some View {
        Button(store.runs[s.id] == nil ? "启动" : "停止") { store.toggle(s.id) }
        Button("重启") { store.restart(s.id) }
        if let url = store.primaryURL(s.id) {
            Button("复制 \(url)") { copy(url) }
            Button("在浏览器打开") { NSWorkspace.shared.open(URL(string: url)!) }
        }
        Divider()
        Button("编辑…") { editing = s }
        Button("在 Finder 中打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: s.dir)) }
        Divider()
        Button("删除…", role: .destructive) { confirmDelete = s }
    }
}

struct ServiceRow: View {
    @Environment(Store.self) private var store
    let service: Service

    var body: some View {
        let st = store.status(service.id)
        HStack(spacing: 10) {
            StatusDot(status: st)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).fontWeight(.medium).lineLimit(1)
                Text(subtitle(st)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.portBlocked(service.id) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .help("端口 \(service.port ?? 0) 被其他进程占用")
            } else if service.autostart {
                Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.tertiary).help("自动启动")
            }
        }
        .padding(.vertical, 3)
    }

    func subtitle(_ st: Status) -> String {
        let where_ = store.links(service.id).first.map { ":\($0.port)" } ?? (service.dir as NSString).lastPathComponent
        switch st {
        case .running: return "运行中 · \(where_)"
        case .stopping: return "停止中…"
        case .crashed(let c): return "异常退出 (\(c)) · \(where_)"
        case .exited: return "已退出 · \(where_)"
        case .stopped: return where_
        }
    }
}

struct StatusDot: View {
    let status: Status
    var body: some View {
        Circle().fill(Color(nsColor: status.color)).frame(width: 9, height: 9)
            .overlay {
                if case .running = status {
                    Circle().stroke(Color(nsColor: status.color).opacity(0.35), lineWidth: 3).frame(width: 13, height: 13)
                }
            }
            .frame(width: 14)
    }
}

// MARK: - 详情

struct DetailView: View {
    @Environment(Store.self) private var store
    let service: Service
    @Binding var editing: Service?
    @State private var log = LogController()
    @State private var follow = true
    @State private var copied: String?

    var body: some View {
        let st = store.status(service.id)
        let run = store.runs[service.id]
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(service.name).font(.title2.weight(.semibold)).lineLimit(1)
                        StatusLine(status: st, run: run)
                    }
                    Spacer()
                    controls(st)
                }

                HStack(spacing: 8) {
                    ForEach(store.links(service.id), id: \.self) { link in
                        let live = run != nil && (link.auto || (store.portOpen[service.id] == true && !store.portBlocked(service.id)))
                        Chip(icon: live ? "dot.radiowaves.left.and.right" : "link",
                             text: copied == link.url ? "已复制" : link.url,
                             tint: live ? .green : .accentColor,
                             badge: link.auto ? "自动" : nil) {
                            copy(link.url)
                            copied = link.url
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = nil }
                        }
                        .help(link.auto ? "自动检测到的 web 端口 · 点击复制，右键可固定" : live ? "端口已在监听 · 点击复制" : "点击复制")
                        .contextMenu {
                            Button("复制 \(link.url)") { copy(link.url) }
                            Button("在浏览器打开") { NSWorkspace.shared.open(URL(string: link.url)!) }
                            if link.auto { Button("固定为该服务的端口") { store.pinPort(service.id, link.port) } }
                        }
                        Button { NSWorkspace.shared.open(URL(string: link.url)!) } label: { Image(systemName: "safari") }
                            .buttonStyle(.borderless).help("在浏览器打开")
                    }
                    if run != nil && store.detected[service.id] == nil && service.port == nil {
                        Text("检测端口中…").font(.caption).foregroundStyle(.tertiary)
                    }
                    let others = store.otherPorts(service.id)
                    if !others.isEmpty {
                        Text("其它监听端口 " + others.map(String.init).joined(separator: ", "))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help("这些端口不响应 HTTP（可能是调试、RPC、WebSocket 等）")
                    }
                    Chip(icon: "folder", text: abbreviate(service.dir), tint: .secondary) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: service.dir))
                    }
                    .help("在 Finder 中打开")
                    Spacer()
                }

                Text(service.cmd)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                if store.portBlocked(service.id), let port = service.port {
                    PortConflictBanner(port: port, running: run != nil, owners: store.foreignOwners(service.id))
                }
            }
            .padding(20)

            Divider()
            HStack(spacing: 14) {
                Label("输出", systemImage: "text.alignleft").font(.callout.weight(.medium))
                Spacer()
                Toggle("自动滚动", isOn: $follow).toggleStyle(.checkbox).controlSize(.small)
                    .onChange(of: follow) { _, v in log.follow = v; if v { log.textView?.scrollToEndOfDocument(nil) } }
                Button("清空") { store.clearLog(service.id); log.reset() }
                    .buttonStyle(.borderless).controlSize(.small)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.logPath(service.id))])
                } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderless).help("在 Finder 中显示日志文件")
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.bar)
            LogView(controller: log)
        }
        .onAppear { log.attach(store.logPath(service.id)) }
        .onDisappear { log.detach() }
    }

    @ViewBuilder func controls(_ st: Status) -> some View {
        HStack(spacing: 8) {
            Button { editing = service } label: { Image(systemName: "slider.horizontal.3") }
                .help("编辑").controlSize(.large)
            switch st {
            case .running, .stopping:
                Button { store.restart(service.id) } label: { Label("重启", systemImage: "arrow.clockwise") }
                    .controlSize(.large).keyboardShortcut("r")
                Button { store.stop(service.id) } label: { Label("停止", systemImage: "stop.fill") }
                    .controlSize(.large).tint(.red).buttonStyle(.borderedProminent)
                    .disabled({ if case .stopping = st { return true }; return false }())
                    .keyboardShortcut(".")
            default:
                Button { store.tryStart(service.id) } label: { Label("启动", systemImage: "play.fill").frame(minWidth: 56) }
                    .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut("r")
            }
        }
    }
}

struct StatusLine: View {
    let status: Status
    let run: Run?
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(text).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
    var text: String {
        switch status {
        case .running: return "运行中 · PID \(run?.pid ?? 0) · 已运行 \(uptime(run?.started ?? .now))"
        case .stopping: return "正在停止…"
        case .crashed(let c): return "异常退出，退出码 \(c)"
        case .exited(let c): return c == nil ? "已退出" : "已退出，退出码 \(c!)"
        case .stopped: return "未运行"
        }
    }
}

struct Chip: View {
    let icon: String
    let text: String
    let tint: Color
    var badge: String? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                Text(text).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if let badge {
                    Text(badge).font(.caption2.weight(.medium)).padding(.horizontal, 4)
                        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(hover ? 0.18 : 0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 编辑

struct EditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: Service
    let isNew: Bool
    let onSave: (Service) -> Void
    @State private var portText = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $draft.name, prompt: Text("例如 ComfyUI"))
                    LabeledContent("启动目录") {
                        HStack {
                            TextField("", text: $draft.cwd, prompt: Text("~/projects/xxx，留空为主目录"))
                                .labelsHidden()
                            Button("选择…") { pickDir() }
                        }
                    }
                    TextField("端口", text: $portText, prompt: Text("可选，留空则运行后自动检测"))
                        .onChange(of: portText) { _, v in
                            let f = v.filter(\.isNumber)
                            if f != v { portText = f }
                        }
                }
                Section {
                    TextEditor(text: $draft.cmd)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("启动命令")
                } footer: {
                    Text("用 zsh 执行，可写多行，例如 conda activate env ⏎ python main.py").foregroundStyle(.secondary)
                }
                Section {
                    Toggle("随 Procman 自动启动", isOn: $draft.autostart)
                    Toggle("异常退出时自动重启", isOn: $draft.restart)
                    Toggle("先加载 ~/.zshrc（conda / nvm / pyenv 需要）", isOn: $draft.zshrc)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "添加" : "保存") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespaces)
                    draft.cwd = draft.cwd.trimmingCharacters(in: .whitespaces)
                    draft.cmd = draft.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.port = Int(portText)
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || draft.cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520)
        .onAppear { portText = draft.port.map(String.init) ?? "" }
    }

    func pickDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: draft.dir)
        if p.runModal() == .OK, let u = p.url { draft.cwd = abbreviate(u.path) }
    }
}

// MARK: - 菜单栏

struct MenuContent: View {
    @Environment(Store.self) private var store
    var body: some View {
        if store.services.isEmpty { Text("还没有服务") }
        ForEach(store.services) { s in
            let running = store.runs[s.id] != nil
            Menu("\(running ? "🟢" : "⚪️")  \(s.name)\(store.links(s.id).first.map { "  :\($0.port)" } ?? "")") {
                Button(running ? "停止" : "启动") { store.toggle(s.id) }
                Button("重启") { store.restart(s.id) }
                if let url = store.primaryURL(s.id) {
                    Divider()
                    Button("复制 \(url)") { copy(url) }
                    Button("在浏览器打开") { NSWorkspace.shared.open(URL(string: url)!) }
                }
                Divider()
                Button("查看输出…") { UserDefaults.standard.set(s.id, forKey: "selected"); store.openMain?() }
            }
        }
        Divider()
        Button("打开 Procman") { store.openMain?() }.keyboardShortcut("o")
        Button("端口占用…") { store.openPorts?() }
        Toggle("登录时启动", isOn: Binding(get: { store.loginItem }, set: { store.setLoginItem($0) }))
        Divider()
        Button("退出（服务保持运行）") { NSApp.terminate(nil) }.keyboardShortcut("q")
        Button("停止全部服务并退出") { store.stopAllAndQuit() }
    }
}

struct MenuLabel: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let n = store.runningCount
        Image(systemName: n > 0 ? "shippingbox.fill" : "shippingbox")
            .onAppear {
                guard store.openMain == nil else { return }
                store.openPorts = {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "ports")
                    NSApp.activate(ignoringOtherApps: true)
                }
                store.openMain = {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                // LSUIElement 应用不会自动弹主窗口，手动打开时这里主动打开
                if !Store.background { DispatchQueue.main.async { store.openMain?() } }
            }
    }
}

// MARK: - 工具

/// 关掉最后一个普通窗口后隐藏 Dock 图标，只留菜单栏
func updateActivationPolicy() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        let visible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0.level == .normal }
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

func uptime(_ d: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(d)))
    let (dd, h, m) = (s / 86400, s % 86400 / 3600, s % 3600 / 60)
    if dd > 0 { return "\(dd) 天 \(h) 小时" }
    if h > 0 { return "\(h) 小时 \(m) 分" }
    if m > 0 { return "\(m) 分 \(s % 60) 秒" }
    return "\(s) 秒"
}
