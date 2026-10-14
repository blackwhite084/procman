import AppKit
import SwiftUI

// MARK: - 详情页的端口冲突提示

struct PortConflictBanner: View {
    @Environment(Store.self) private var store
    let port: Int
    let running: Bool
    let owners: [Listener]
    @State private var confirm: Listener?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(running ? "端口 \(port) 被其他进程占用，本服务可能没能监听成功"
                          : "端口 \(port) 已被占用，启动可能会失败",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            if owners.isEmpty {
                Text("看不到占用者（可能是 root / 系统进程）。终端里可用 sudo lsof -iTCP:\(port) -sTCP:LISTEN 查看。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(owners) { l in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(l.command)  ·  PID \(l.pid)  ·  \(l.user)").font(.callout.weight(.medium))
                        Text(l.args).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    Button("结束进程") { confirm = l }
                    if let s = store.serviceOwning(l) {
                        Text("属于「\(s.name)」").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35)))
        .killConfirm($confirm)
    }
}

// MARK: - 端口占用窗口

struct PortsView: View {
    @Environment(Store.self) private var store
    @State private var listeners: [Listener] = []
    @State private var query = ""
    @State private var selection = Set<Listener.ID>()
    @State private var confirm: Listener?
    @State private var loading = false
    @State private var sort = [KeyPathComparator(\Listener.port)]

    var filtered: [Listener] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? listeners : listeners.filter {
            String($0.port).hasPrefix(q) || String($0.pid) == q
                || $0.command.lowercased().contains(q) || $0.args.lowercased().contains(q)
        }
        return list.sorted(using: sort)
    }

    var body: some View {
        Table(filtered, selection: $selection, sortOrder: $sort) {
            TableColumn("端口", value: \.port) { l in
                Text(String(l.port)).font(.body.monospacedDigit().weight(.medium))
            }
            .width(min: 50, ideal: 64, max: 80)
            TableColumn("进程", value: \.command) { l in
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.command).lineLimit(1)
                    Text("PID \(l.pid) · \(l.user)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 110, ideal: 150)
            TableColumn("命令") { l in
                Text(l.args).font(.system(.caption, design: .monospaced)).lineLimit(2)
                    .truncationMode(.middle).help(l.args)
            }
            TableColumn("地址") { l in
                Text(l.addrs.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 110)
            TableColumn("服务") { l in
                if let s = store.serviceOwning(l) {
                    Text(s.name).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.green.opacity(0.15), in: Capsule())
                }
            }
            .width(min: 50, ideal: 90)
            TableColumn("") { l in
                Button("结束") { confirm = l }.controlSize(.small)
            }
            .width(52)
        }
        .contextMenu(forSelectionType: Listener.ID.self) { ids in
            if let l = listeners.first(where: { ids.contains($0.id) }) { rowMenu(l) }
        } primaryAction: { ids in
            if let l = listeners.first(where: { ids.contains($0.id) }) {
                NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(l.port)")!)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "端口 / PID / 进程 / 命令")
        .toolbar {
            ToolbarItem {
                Button { Task { await refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(loading)
            }
        }
        .overlay {
            if listeners.isEmpty && !loading {
                ContentUnavailableView("没有正在监听的端口", systemImage: "network.slash")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(filtered.count) 个监听端口 · 每 3 秒刷新 · 双击在浏览器打开 · 右键更多操作")
                Spacer()
                Text("仅显示当前用户可见的进程").foregroundStyle(.tertiary)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
        .killConfirm($confirm) { Task { try? await Task.sleep(for: .milliseconds(700)); await refresh() } }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .frame(minWidth: 640, minHeight: 320)
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        .onDisappear(perform: updateActivationPolicy)
    }

    @ViewBuilder func rowMenu(_ l: Listener) -> some View {
        Button("在浏览器打开 http://127.0.0.1:\(l.port)") {
            NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(l.port)")!)
        }
        Button("复制地址") { copy("http://127.0.0.1:\(l.port)") }
        Button("复制 PID") { copy(String(l.pid)) }
        Button("复制命令") { copy(l.args) }
        Divider()
        if store.serviceOwning(l) == nil {
            Button("添加为服务…") { addAsService(l) }
            Divider()
        }
        Button("结束进程…") { confirm = l }
        Button("强制结束 (SIGKILL)", role: .destructive) {
            store.killListener(l, force: true)
            Task { try? await Task.sleep(for: .milliseconds(500)); await refresh() }
        }
    }

    func refresh() async {
        loading = true
        let list = await Task.detached(priority: .utility) { listListeners() }.value
        if list != listeners { listeners = list }
        loading = false
    }

    /// 用正在运行的进程预填一个新服务（目录取进程当前工作目录）
    func addAsService(_ l: Listener) {
        Task {
            let cwd = await Task.detached { procCwd(l.pid) }.value
            var s = Service()
            s.name = "\(l.command):\(l.port)"
            s.cwd = cwd.map(abbreviate) ?? ""
            s.cmd = l.args
            s.port = l.port
            store.pendingNew = s
            store.openMain?()
        }
    }
}

// MARK: - 结束进程确认

extension View {
    func killConfirm(_ target: Binding<Listener?>, after: @escaping () -> Void = {}) -> some View {
        modifier(KillConfirm(target: target, after: after))
    }
}

private struct KillConfirm: ViewModifier {
    @Environment(Store.self) private var store
    @Binding var target: Listener?
    let after: () -> Void

    func body(content: Content) -> some View {
        content.alert("结束「\(target?.command ?? "")」(PID \(target.map { String($0.pid) } ?? ""))？",
                      isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                      presenting: target) { l in
            Button("结束进程", role: .destructive) { store.killListener(l); after() }
            Button("强制结束") { store.killListener(l, force: true); after() }
            Button("取消", role: .cancel) {}
        } message: { l in
            let owner = store.serviceOwning(l).map { "它属于服务「\($0.name)」。\n\n" } ?? ""
            Text("\(owner)端口 \(l.port) · 用户 \(l.user)\n\(l.args.prefix(300))\n\n「结束进程」先发 SIGTERM，5 秒未退出再强制结束；无权限时会请求管理员密码。")
        }
    }
}
