import ServerKilnCore
import ServiceManagement
import SwiftUI
import ServerKilnUI
import ServerKilnSync
import ServerKilnSSH

enum SettingsPage: String, CaseIterable, Identifiable {
    case servers, phone, general, notifications, history

    var id: String { rawValue }
    var title: String {
        switch self {
        case .servers: return String(appLocalized: "服务器")
        case .phone: return "iPhone"
        case .general: return String(appLocalized: "通用")
        case .notifications: return String(appLocalized: "通知")
        case .history: return String(appLocalized: "历史数据")
        }
    }
    var icon: String {
        switch self {
        case .servers: return "server.rack"
        case .phone: return "iphone"
        case .general: return "gearshape"
        case .notifications: return "bell"
        case .history: return "chart.xyaxis.line"
        }
    }
}

/// Settings window drawn with the same material, cards and controls as the
/// menu bar panel.
struct SettingsView: View {
    @State private var page: SettingsPage

    init(initialPage: SettingsPage = .servers) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage ?? BrandMark.menuBarImage)
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text("ServerKiln").font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
                ForEach(SettingsPage.allCases) { p in
                    Button { page = p } label: {
                        HStack(spacing: 8) {
                            Image(systemName: p.icon).frame(width: 16)
                            Text(p.title)
                            Spacer()
                        }
                        .font(.system(size: 12, weight: page == p ? .semibold : .regular))
                        .foregroundStyle(page == p ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(page == p ? Color.primary.opacity(0.1) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
            .padding(12)
            .padding(.top, 22)
            .frame(width: 168)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(page.title).font(.system(size: 17, weight: .semibold))
                    switch page {
                    case .servers: ServersSettings()
                    case .phone: PhoneSettings()
                    case .general: GeneralSettings()
                    case .notifications: NotificationSettings()
                    case .history: HistorySettings()
                    }
                }
                .padding(20)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 480)
        .background(VisualEffectBackground().ignoresSafeArea())
    }
}

// MARK: - Building blocks

/// A card with titled rows, like a grouped form section.
struct SettingsGroup<Content: View>: View {
    var title: String?
    /// Explanation behind an ⓘ next to the title, instead of footer text.
    var info: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || info != nil {
                HStack(spacing: 4) {
                    if let title { SectionTitle(title) }
                    if let info { InfoButton(text: info, size: 10) }
                }
                .padding(.leading, 4)
            }
            _VariadicView.Tree(DividedLayout()) { content }
                .card()
        }
    }
}

/// Stacks rows with hairline dividers between them (macOS 14 compatible).
private struct DividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                if child.id != children.last?.id {
                    Divider().opacity(0.5).padding(.leading, 12)
                }
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var info: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12))
                if let info { InfoButton(text: info) }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

struct SettingsToggle: View {
    var title: String
    var info: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12))
                if let info { InfoButton(text: info) }
            }
        }
        .toggleStyle(CapsuleToggleStyle())
    }
}

/// Text field drawn as a soft rounded well.
struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Servers

struct ServersSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Monitor.self) private var monitor
    @Environment(PhoneSync.self) private var phone
    @State private var showImport = false
    @State private var editing: ServerConfig?
    @State private var testResult: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { editing = ServerConfig(name: "", target: "") } label: { Label("添加", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Button { showImport = true } label: { Label("从 SSH 配置导入", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PillButtonStyle())
                Spacer()
                Text("\(settings.servers.count) 台").font(.caption).foregroundStyle(.secondary)
            }

            if let editing {
                ServerEditor(server: editing) { result in save(result) }
                    .padding(14)
                    .card(highlighted: true)
            }
            if showImport {
                ImportView { showImport = false }
                    .card(highlighted: true)
            }

            if settings.servers.isEmpty {
                Text("还没有服务器").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .card()
            } else {
                VStack(spacing: 6) {
                    ForEach(settings.servers) { server in row(server) }
                }
            }
        }
    }

    private func row(_ server: ServerConfig) -> some View {
        let binding = Binding(
            get: { settings.servers.first { $0.id == server.id } ?? server },
            set: { new in
                if let i = settings.servers.firstIndex(where: { $0.id == server.id }) { settings.servers[i] = new }
            }
        )
        let index = settings.servers.firstIndex { $0.id == server.id } ?? 0
        return HStack(spacing: 10) {
            StatusDot(status: server.enabled ? monitor.connection(server) : .connecting)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(server.enabled ? Color.primary : Color.secondary)
                Text(server.target + (server.port.map { ":\($0)" } ?? ""))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let r = testResult[server.id] {
                Text(r).font(.caption2).foregroundStyle(r.hasPrefix("✓") ? Color.green : r.hasPrefix("✗") ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
            HStack(spacing: 0) {
                Button { move(server, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0).help("上移")
                Button { move(server, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == settings.servers.count - 1).help("下移")
                Button { test(server) } label: { Image(systemName: "bolt.horizontal") }.help("测试连接")
                Button { binding.wrappedValue.muted.toggle() } label: {
                    Image(systemName: server.muted ? "bell.slash" : "bell")
                }
                .help(server.muted ? "已静音此服务器通知" : "静音此服务器通知")
                Button { editing = server } label: { Image(systemName: "pencil") }.help("编辑")
                Button { remove(server.id) } label: { Image(systemName: "trash") }.help("删除")
            }
            .buttonStyle(IconButtonStyle())
            Toggle("", isOn: Binding(
                get: { binding.wrappedValue.enabled },
                set: { binding.wrappedValue.enabled = $0; monitor.sync() }
            ))
            .labelsHidden()
            .toggleStyle(CapsuleToggleStyle())
            .frame(width: 34)
            .help("启用监控")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card()
    }

    private func save(_ result: ServerConfig?) {
        if let result {
            if let i = settings.servers.firstIndex(where: { $0.id == result.id }) {
                settings.servers[i] = result
            } else {
                settings.servers.append(result)
            }
            monitor.restart()
        }
        editing = nil
    }

    private func move(_ server: ServerConfig, by delta: Int) {
        guard let i = settings.servers.firstIndex(where: { $0.id == server.id }) else { return }
        let j = i + delta
        guard settings.servers.indices.contains(j) else { return }
        settings.servers.swapAt(i, j)
    }

    private func remove(_ id: UUID) {
        // Revoke the phone's keys while the full ssh config is still known.
        if let server = settings.servers.first(where: { $0.id == id }), phone.synced[id] != nil {
            phone.revoke(server)
        }
        settings.servers.removeAll { $0.id == id }
        monitor.sync()
        Task { await monitor.history.delete(server: id) }
    }

    private func test(_ server: ServerConfig) {
        testResult[server.id] = String(appLocalized: "测试中…")
        Task {
            do {
                let snap = try await SSHRunner.fetch(server)
                testResult[server.id] = snap.isGPUServer ? String(appLocalized: "✓ \(snap.gpus.count) 张 GPU") : String(appLocalized: "✓ 仅 CPU")
            } catch {
                testResult[server.id] = "✗ \(error.localizedDescription)"
            }
        }
    }
}

struct ServerEditor: View {
    @State var server: ServerConfig
    var onFinish: (ServerConfig?) -> Void
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(server.target.isEmpty ? "添加服务器" : "编辑服务器").font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("显示名称").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $server.name, prompt: Text("8x4090")).modifier(FieldStyle())
                }
                GridRow {
                    Text("SSH 目标").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $server.target, prompt: Text("Host 别名 或 user@host")).modifier(FieldStyle())
                }
                GridRow {
                    Text("端口").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $portText, prompt: Text("可选，默认使用 ssh 配置")).modifier(FieldStyle())
                }
            }
            Text("SSH 目标会原样传给 ssh。推荐使用 ~/.ssh/config 中的 Host 别名，以复用其中的密钥与跳板机配置；需支持免密登录。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { onFinish(nil) }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    var s = server
                    s.target = s.target.trimmingCharacters(in: .whitespaces)
                    if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = s.target }
                    s.port = Int(portText.trimmingCharacters(in: .whitespaces))
                    onFinish(s)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(server.target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { portText = server.port.map(String.init) ?? "" }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: String(appLocalized: "语言")) {
                SettingsRow(title: String(appLocalized: "显示语言")) {
                    AppLanguagePicker().fixedSize()
                }
            }
            MacUpdateSettings()
            SettingsGroup(title: String(appLocalized: "菜单栏")) {
                SettingsRow(title: String(appLocalized: "显示布局")) {
                    PillPicker(selection: $settings.menuBarDualRow, options: [(false, String(appLocalized: "单行")), (true, String(appLocalized: "双行"))])
                }
                menuBarStyleRow(settings.menuBarDualRow ? String(appLocalized: "上行内容") : String(appLocalized: "显示内容"), selection: $settings.menuBarStyle)
                if settings.menuBarDualRow {
                    menuBarStyleRow(String(appLocalized: "下行内容"), selection: $settings.menuBarSecondStyle)
                }
            }

            SettingsGroup(title: String(appLocalized: "刷新"), info: String(appLocalized: "打开菜单栏面板时自动切换为快速刷新，关闭后恢复后台间隔。每台服务器独立轮询，SSH 连接会被复用。")) {
                SettingsRow(title: String(appLocalized: "后台刷新间隔")) {
                    PillPicker(selection: $settings.refreshInterval, options: [(10.0, "10s"), (30.0, "30s"), (60.0, "1m"), (300.0, "5m")])
                }
                SettingsRow(title: String(appLocalized: "面板打开时")) {
                    PillPicker(selection: $settings.fastRefreshInterval, options: [(1.0, "1s"), (2.0, "2s"), (3.0, "3s"), (5.0, "5s")])
                }
            }

            SettingsGroup(title: String(appLocalized: "忙碌判定"), info: String(appLocalized: "满足任一条件即视为该卡正在使用。显存条件用于覆盖数据加载、保存检查点等利用率暂时为 0 的间隙。")) {
                SettingsRow(title: String(appLocalized: "GPU 利用率 ≥")) {
                    Slider(value: Binding(get: { settings.utilizationThreshold },
                                          set: { settings.utilizationThreshold = $0.rounded() }), in: 1...90)
                        .controlSize(.small).frame(width: 180)
                    Text("\(Int(settings.utilizationThreshold))%").monospacedDigit().font(.caption).frame(width: 40, alignment: .trailing)
                }
                SettingsRow(title: String(appLocalized: "或 显存占用 ≥")) {
                    Slider(value: Binding(get: { settings.memoryThresholdMiB },
                                          set: { settings.memoryThresholdMiB = ($0 / 256).rounded() * 256 }), in: 256...16384)
                        .controlSize(.small).frame(width: 180)
                    Text(Format.mib(settings.memoryThresholdMiB)).monospacedDigit().font(.caption).frame(width: 40, alignment: .trailing)
                }
            }

            SettingsGroup {
                SettingsToggle(title: String(appLocalized: "登录时启动"), isOn: $launchAtLogin)
            }
            .onChange(of: launchAtLogin) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        }
    }

    private func menuBarStyleRow(_ title: String, selection: Binding<MenuBarStyle>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 12)).fixedSize()
                Spacer(minLength: 12)
                menuBarPicker(selection)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12))
                menuBarPicker(selection).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func menuBarPicker(_ selection: Binding<MenuBarStyle>) -> some View {
        PillPicker(selection: selection, options: MenuBarStyle.allCases.map { ($0, $0.shortTitle) })
            .fixedSize()
            .help(selection.wrappedValue.title)
    }
}

extension MenuBarStyle {
    var shortTitle: String {
        switch self {
        case .servers: return String(appLocalized: "服务器数")
        case .serversAndGPUs: return String(appLocalized: "服务器·卡数")
        case .busyOverTotal: return String(appLocalized: "忙/总")
        case .gpus: return String(appLocalized: "卡")
        case .vram: return String(appLocalized: "显存")
        }
    }
}

// MARK: - Notifications

struct NotificationSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: String(appLocalized: "通知我")) {
                SettingsToggle(title: String(appLocalized: "训练结束"), info: String(appLocalized: "服务器所有卡变为空闲"), isOn: $settings.notifyOnIdle)
                SettingsToggle(title: String(appLocalized: "开始训练"), info: String(appLocalized: "空闲服务器上有卡开始使用"), isOn: $settings.notifyOnBusy)
                SettingsToggle(title: String(appLocalized: "离线 / 恢复"), info: String(appLocalized: "SSH 连接失败或恢复"), isOn: $settings.notifyOnOffline)
            }
            SettingsGroup(title: String(appLocalized: "防抖"), info: String(appLocalized: "状态需连续保持这么多次后台刷新才会通知。可在「服务器」页对单台服务器静音。")) {
                SettingsRow(title: String(appLocalized: "连续确认次数")) {
                    PillPicker(selection: $settings.debounceCount, options: [1, 2, 3, 5].map { ($0, String(appLocalized: "\($0) 次")) })
                }
            }
            if !Notifier.isAvailable {
                Text("通过 swift run 运行时通知不可用，请使用打包后的 ServerKiln.app。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - iPhone

/// PRD §5.9: per-server dedicated keys for the iPhone, iCloud sync status
/// and push of busy/idle transitions.
struct PhoneSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PhoneSync.self) private var phone
    @State private var showDownload = false
    @State private var withTerminal = true
    @State private var confirmRevoke: UUID?

    var body: some View {
        @Bindable var phone = phone
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow(title: String(appLocalized: "下载 iPhone 版")) {
                    Button { showDownload = true } label: {
                        Label("扫码下载", systemImage: "qrcode")
                    }
                    .buttonStyle(PillButtonStyle())
                    Link(destination: PhoneDownloadView.websiteURL) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(Text("访问官网"))
                    .accessibilityLabel(Text("访问官网"))
                }
            }
            .sheet(isPresented: $showDownload) { PhoneDownloadView() }
            SettingsGroup(title: "iCloud") {
                SettingsRow(title: phone.account?.message ?? String(appLocalized: "正在检查 iCloud…"),
                            info: String(appLocalized: "服务器列表存于你的 iCloud 私有数据库；私钥只存 iCloud 钥匙串（端到端加密），不会写入任何文件或数据库。")) {
                    Image(systemName: isAvailable ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill")
                        .foregroundStyle(isAvailable ? Color.green : Color.orange)
                }
                SettingsToggle(title: String(appLocalized: "推送到 iPhone"),
                               info: String(appLocalized: "训练结束 / 开始 / 离线时经 iCloud 推送到 iPhone，沿用「通知」页的防抖与静音。Mac 休眠或关机时不会推送。"),
                               isOn: $phone.pushEnabled)
                SettingsToggle(title: String(appLocalized: "状态中转"),
                               info: String(appLocalized: "把本机看到的服务器状态每分钟同步一次到 iCloud（状态变化时立即同步）。iPhone 直连不到的机器（只有这台 Mac 能访问的内网、ZeroTier 等）也能在手机和小组件上看到；未为 iPhone 启用的服务器只显示状态，不能打开终端。可在下方每台服务器右侧的分叉图标单独关闭。"),
                               isOn: $phone.relayEnabled)
                SettingsToggle(title: String(appLocalized: "同时部署终端密钥"),
                               info: String(appLocalized: "额外部署一把可开 shell 的密钥（禁止一切端口 / agent 转发）。iPhone 每次打开终端前需要 Face ID。"),
                               isOn: $withTerminal)
            }
            if let error = phone.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            SettingsGroup(title: String(appLocalized: "服务器"), info: securityInfo) {
                ForEach(settings.servers) { server in row(server) }
            }
        }
        .task { await phone.refreshAccount() }
    }

    private var isAvailable: Bool {
        if case .available = phone.account { return true }
        return false
    }

    private var securityInfo: String {
        String(appLocalized: "启用时 Mac 通过你现有的 SSH 连接生成 Ed25519 专属密钥：监控密钥在 authorized_keys 中被限定为只能运行只读采集脚本；")
            + String(appLocalized: "主机公钥经已认证连接读取并钉扎，iPhone 不会连接密钥不符的主机。撤销会同时删除服务器上的授权与 iCloud 钥匙串中的私钥。")
    }

    @ViewBuilder private func row(_ server: ServerConfig) -> some View {
        let record = phone.synced[server.id]
        let working = phone.busy.contains(server.id)
        let problem = problemText(server)
        HStack(spacing: 8) {
            Image(systemName: record == nil ? "iphone.slash" : "iphone")
                .foregroundStyle(record == nil ? Color.secondary : Color.green)
                .frame(width: 16)
            Text(server.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if record?.hasTerminal == true {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary).help("已部署终端密钥")
            }
            if let detail = detailText(record) { InfoButton(text: detail) }
            if let problem {
                InfoButton(text: problem.text, symbol: "exclamationmark.circle.fill", tint: problem.color)
            }
            Spacer(minLength: 8)
            if phone.relayEnabled && !working {
                // Per-server relay switch: lit = this Mac relays its status.
                let relayed = !phone.relayExcluded.contains(server.id)
                Button {
                    if relayed { phone.relayExcluded.insert(server.id) } else { phone.relayExcluded.remove(server.id) }
                } label: {
                    Image(systemName: relayed ? "arrow.triangle.branch" : "arrow.triangle.branch")
                        .foregroundStyle(relayed ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                .buttonStyle(IconButtonStyle())
                .help(relayed ? "状态中转到 iPhone：开（点击关闭）" : "状态中转到 iPhone：关（点击开启）")
            }
            if working {
                Text(phone.status[server.id] ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                ProgressView().controlSize(.small)
            } else if record != nil {
                if confirmRevoke == server.id {
                    Button("取消") { confirmRevoke = nil }.buttonStyle(PillButtonStyle())
                    Button("撤销") {
                        confirmRevoke = nil
                        phone.revoke(server)
                    }
                    .buttonStyle(PillButtonStyle(destructive: true))
                } else {
                    Button { phone.deploy(server, terminal: withTerminal) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .buttonStyle(IconButtonStyle())
                        .help("轮换密钥")
                    Button("撤销…") { confirmRevoke = server.id }.buttonStyle(PillButtonStyle(destructive: true))
                }
            } else {
                Button("启用") { phone.deploy(server, terminal: withTerminal) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(!phone.isAvailable)
            }
        }
    }

    private func detailText(_ record: SyncedServer?) -> String? {
        guard let record else { return nil }
        let ep = record.endpoint
        var lines = ["\(ep.user)@\(ep.host):\(ep.port)", record.hasTerminal ? String(appLocalized: "监控 + 终端密钥") : String(appLocalized: "仅监控密钥")]
        lines += ep.hostKeys.compactMap(HostKey.fingerprint).map { String(appLocalized: "主机密钥 \($0)") }
        lines.append(String(appLocalized: "部署于 ") + record.deployedAt.formatted(date: .abbreviated, time: .shortened))
        return lines.joined(separator: "\n")
    }

    private func problemText(_ server: ServerConfig) -> (text: String, color: Color)? {
        guard !phone.busy.contains(server.id), let s = phone.status[server.id] else { return nil }
        if s.hasPrefix("✗") { return (String(s.dropFirst(2)), .red) }
        if s.hasPrefix("⚠︎") { return (String(s.dropFirst(3)), .orange) }
        return nil
    }
}

// MARK: - History

struct HistorySettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @State private var size: Int64 = 0
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: String(appLocalized: "存储"), info: String(appLocalized: "每台服务器每分钟记录一次整体与每张卡的利用率、显存，以及 CPU / 内存。数据保存在本机 ~/Library/Application Support/ServerKiln。")) {
                SettingsRow(title: String(appLocalized: "保留时长")) {
                    PillPicker(selection: $settings.historyRetentionDays, options: [(7, String(appLocalized: "7 天")), (30, String(appLocalized: "30 天")), (90, String(appLocalized: "90 天"))])
                }
                SettingsRow(title: String(appLocalized: "已用空间")) {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: settings.historyRetentionDays) { _, days in
                Task {
                    await monitor.history.configure(retentionDays: days)
                    size = await monitor.history.sizeInBytes()
                }
            }
            HStack {
                Button {
                    openWindow(id: "history")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("打开历史曲线", systemImage: "chart.xyaxis.line") }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Spacer()
                if confirmClear {
                    Text("确定清空全部历史？").font(.caption).foregroundStyle(.secondary)
                    Button("取消") { confirmClear = false }.buttonStyle(PillButtonStyle())
                    Button("清空") {
                        confirmClear = false
                        Task {
                            await monitor.history.deleteAll()
                            size = await monitor.history.sizeInBytes()
                        }
                    }
                    .buttonStyle(PillButtonStyle(destructive: true))
                } else {
                    Button("清空历史…") { confirmClear = true }.buttonStyle(PillButtonStyle(destructive: true))
                }
            }
        }
        .task { size = await monitor.history.sizeInBytes() }
    }
}
