import ServerKilnCore
import SwiftUI
import ServerKilnUI

struct PanelView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: Set<UUID>
    @State private var showImport = false
    @ObservedObject private var updater = MacUpdater.shared

    init(initiallyExpanded: Set<UUID> = []) {
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showImport {
                // Sheets are unreliable inside MenuBarExtra windows; show inline.
                ImportView { showImport = false }
            } else if !settings.finishedGuide {
                GuideView(showImport: $showImport)
            } else if settings.servers.isEmpty {
                OnboardingView(showImport: $showImport)
            } else {
                header
                ScrollView(.vertical) { serverList }
                    // Unlike .hidden, .never also overrides macOS's
                    // "Always show scroll bars" preference.
                    .scrollIndicators(.never)
                    .frame(maxHeight: 560)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 400)
        .transaction { $0.animation = nil }
        .background(WindowVisibilityReader { visible in
            Task { @MainActor in Monitor.shared.setPanelVisible(visible) }
        })
    }

    private var serverList: some View {
        VStack(spacing: 8) {
            ForEach(monitor.sortedServers) { server in
                ServerCard(server: server, isExpanded: expanded.contains(server.id)) {
                    // No animation: the menu bar window resizes in one step,
                    // so animating the content makes it visibly jump.
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        if expanded.contains(server.id) { expanded.remove(server.id) } else { expanded.insert(server.id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .transaction { $0.animation = nil }
    }

    private var header: some View {
        let s = monitor.summary
        var f = FleetSummary()
        f.busyServers = s.busyServers
        f.gpuServers = s.gpuServers
        f.busyGPUs = s.busyGPUs
        f.totalGPUs = s.totalGPUs
        f.online = s.online
        f.offline = s.offline
        f.total = s.total
        return SummaryTiles(f)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle()
                    .fill(monitor.panelVisible ? Color.green : Color.secondary)
                    .frame(width: 5, height: 5)
                Text("每 \(Self.intervalText(monitor.currentInterval)) 刷新")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help("面板打开时加快刷新，关闭后恢复为设置中的间隔")
            Spacer()
            if let version = updater.pendingVersion {
                Button {
                    updater.checkForUpdates()
                } label: { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint) }
                    .help(String(appLocalized: "新版本 \(version) 可用"))
            }
            Button {
                Task { await monitor.refreshAll() }
            } label: { Image(systemName: "arrow.clockwise") }
                .help("立即刷新")
            Button {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Image(systemName: "chart.xyaxis.line") }
                .help("历史曲线")
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Image(systemName: "gearshape") }
                .help("设置")
            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
                .help("退出 ServerKiln")
        }
        .buttonStyle(IconButtonStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    static func intervalText(_ seconds: Double) -> String {
        seconds >= 60 ? String(appLocalized: "\(Int(seconds / 60)) 分钟") : String(appLocalized: "\(Int(seconds)) 秒")
    }
}

/// Three steps for a new install, in the panel itself (sheets are
/// unreliable in MenuBarExtra windows). Ends in the import flow.
struct GuideView: View {
    @Binding var showImport: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var step: Int

    init(showImport: Binding<Bool>, initialStep: Int = 0) {
        _showImport = showImport
        _step = State(initialValue: initialStep)
    }

    private struct Step {
        var symbol: String
        var title: LocalizedStringKey
        var body: LocalizedStringKey
    }

    private let steps: [Step] = [
        Step(symbol: "menubar.rectangle", title: "欢迎使用 ServerKiln",
             body: "菜单栏一眼看清几台 GPU 服务器在训练，点开即可看到每张卡、每个任务。"),
        Step(symbol: "terminal", title: "服务器上无需安装任何东西",
             body: "ServerKiln 通过系统 ssh 运行只读脚本，沿用 ~/.ssh/config 中的别名、密钥与跳板机。需支持免密登录（密钥或 ssh-agent）。"),
        Step(symbol: "iphone.radiowaves.left.and.right", title: "训练结束，Mac 和 iPhone 都提醒",
             body: "在「设置 → iPhone」为服务器启用后，iPhone App 与小组件也能查看状态、接收推送。"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            let s = steps[step]
            ZStack {
                Circle().fill(Brand.ember.opacity(0.14)).frame(width: 74, height: 74)
                Image(systemName: s.symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Brand.ember)
            }
            .padding(.top, 6)
            VStack(spacing: 6) {
                Text(s.title).font(.headline)
                Text(s.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 48, alignment: .top)
            }
            .id(step)
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule().fill(i == step ? Brand.ember : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 14 : 6, height: 6)
                }
            }
            HStack {
                Button(step == 0 ? "跳过" : "上一步") {
                    if step == 0 { settings.finishedGuide = true } else { step -= 1 }
                }
                .buttonStyle(.link)
                .font(.caption)
                Spacer()
                if step < steps.count - 1 {
                    Button("继续") { step += 1 }
                        .buttonStyle(PillButtonStyle(prominent: true, fill: Brand.ember))
                } else {
                    Button {
                        settings.finishedGuide = true
                        showImport = true
                    } label: {
                        Label("从 SSH 配置导入服务器", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(PillButtonStyle(prominent: true, fill: Brand.ember))
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .tint(Brand.ember)
    }
}

struct OnboardingView: View {
    @Binding var showImport: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("欢迎使用 ServerKiln").font(.headline)
                Text("在菜单栏一眼看清所有 GPU 服务器的训练状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                Button {
                    showImport = true
                } label: {
                    Label("从 SSH 配置导入服务器", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                Button("手动添加…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(24)
    }
}
