import AppKit
import ServerKilnCore
import SwiftUI
import ServerKilnUI

/// `ServerKiln --snapshot <out-dir> [ssh-target…]` renders the panel to PNGs for
/// design review. Real targets are fetched live; demo servers fill the rest.
@MainActor
enum SnapshotRenderer {
    /// PID of the task to show expanded in snapshots.
    nonisolated(unsafe) static var openFirstTask: Int?

    static func run(outDir: String, targets: [String]) async {
        do {
            try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        } catch {
            fputs("Cannot create snapshot directory: \(error)\n", stderr)
            exit(1)
        }
        if targets == ["--check-layout"] {
            PanelLayoutCheck.run()
            return
        }
        if targets == ["--check-menubar"] {
            MenuBarLayoutCheck.run()
            return
        }
        let settings = AppSettings.shared
        let monitor = Monitor.shared

        settings.finishedGuide = true
        var servers = targets.map { ServerConfig(name: $0, target: $0) }
        let demo = demoServers()
        servers += demo.map(\.0)
        settings.servers = servers
        for (server, state) in demo { monitor.inject(server.id, state) }
        if let first = demo.first?.0.id {
            let now = Date()
            monitor.injectJobs(first, finished: [
                TaskRecord(command: "/opt/conda/bin/torchrun --nproc_per_node 8 train.py --config configs/qwen2.5-7b-dpo.yaml",
                           user: "ming", cwd: "/home/ming/projects/llm-sft", gpuIndices: Array(0..<8),
                           startedAt: now.addingTimeInterval(-3600 * 30), endedAt: now.addingTimeInterval(-3600 * 2.3)),
                TaskRecord(command: "/opt/conda/bin/python eval.py --ckpt outputs/step-9000 --bench gsm8k",
                           user: "ming", cwd: "/home/ming/projects/llm-sft", gpuIndices: [6, 7],
                           startedAt: now.addingTimeInterval(-3600 * 34), endedAt: now.addingTimeInterval(-3600 * 31)),
            ])
        }
        for server in servers.prefix(targets.count) { await monitor.refresh(server) }

        let busyID = monitor.sortedServers.first { monitor.activity($0) == .busy && $0.name == "h100-sxm-a" }?.id
        let firstID = monitor.sortedServers.first?.id
        render(PanelView(initiallyExpanded: []), name: "panel", outDir: outDir)
        openFirstTask = 182_331
        render(PanelView(initiallyExpanded: Set([busyID ?? firstID].compactMap { $0 })), name: "panel-expanded", outDir: outDir)
        if let jobs = monitor.jobs.values.first {
            render(LastJobSection(last: jobs.last, history: jobs.finished).padding(12).frame(width: 380),
                   name: "last-job", outDir: outDir)
            render(LastJobPreview(jobs: jobs).padding(12).frame(width: 380), name: "last-job-open", outDir: outDir, settle: 0.6)
        }
        if let cpuID = monitor.sortedServers.first(where: { $0.name == "data-cpu" })?.id {
            render(PanelView(initiallyExpanded: [cpuID]), name: "panel-cpu", outDir: outDir)
        }
        openFirstTask = nil
        if targets.count > 0, let real = settings.servers.first?.id {
            render(PanelView(initiallyExpanded: [real]), name: "panel-real", outDir: outDir)
        }
        render(MenuBarLabel().padding(4), name: "menubar", outDir: outDir, scale: 3)
        for style in MenuBarStyle.allCases {
            settings.menuBarStyle = style
            render(MenuBarLabel().padding(4), name: "menubar-\(style.rawValue)", outDir: outDir, scale: 3)
        }
        settings.menuBarStyle = .servers
        settings.menuBarDualRow = true
        settings.menuBarSecondStyle = .vram
        render(MenuBarLabel().padding(4), name: "menubar-dual", outDir: outDir)
        settings.menuBarStyle = .gpus
        settings.menuBarSecondStyle = .busyOverTotal
        render(MenuBarLabel().padding(4), name: "menubar-dual-counts", outDir: outDir)
        settings.menuBarStyle = .servers
        settings.menuBarSecondStyle = .vram
        render(Image(nsImage: BrandMark.menuBarImage).padding(4), name: "menubar-icon", outDir: outDir)
        render(Image(nsImage: BrandMark.menuBarAlertImage).padding(4), name: "menubar-icon-offline", outDir: outDir)

        // History with synthetic data for the first demo server (8× B200).
        if let demoID = demo.first?.0.id {
            await seedHistory(id: demoID)
            monitor.historySelection = demoID
            let since = Date().addingTimeInterval(-86400)
            let agg = await monitor.history.query(server: demoID, since: since, bucket: HistoryRange.day.bucket, perGPU: false)
            let per = await monitor.history.query(server: demoID, since: since, bucket: HistoryRange.day.bucket, perGPU: true)
            render(HistoryView(preloaded: agg), name: "history", outDir: outDir, size: CGSize(width: 900, height: 640), settle: 1.0)
            // Regression: per-GPU mode with stale aggregate points used to trap in Charts.
            render(HistoryView(initialPerGPU: true, preloaded: agg), name: "history-stale", outDir: outDir, size: CGSize(width: 900, height: 640), settle: 0.5)
            render(HistoryView(initialPerGPU: true, preloaded: per), name: "history-pergpu", outDir: outDir, size: CGSize(width: 900, height: 640), settle: 1.0)
            // 10-minute range from 5-second live samples.
            var live: [HistoryPoint] = []
            for i in 0..<120 {
                let t = Date().addingTimeInterval(Double(i - 120) * 5)
                let u = 60 + 35 * sin(Double(i) / 9)
                live.append(HistoryPoint(time: t, gpu: nil, utilization: u, memoryFraction: 0.86, memoryUsedMiB: 168_000,
                                         cpu: 0.4, ram: 0.5))
            }
            render(HistoryView(preloaded: live, initialRange: .tenMinutes), name: "history-10min", outDir: outDir,
                   size: CGSize(width: 900, height: 640), settle: 1.0)
        }

        for page in SettingsPage.allCases {
            render(SettingsPreview(page: page), name: "settings-\(page.rawValue)", outDir: outDir, size: CGSize(width: 640, height: 480))
        }

        render(PhoneDownloadView(), name: "phone-download", outDir: outDir)

        settings.servers = []
        render(PanelView(initiallyExpanded: []), name: "onboarding", outDir: outDir)
        settings.finishedGuide = false
        for step in 0..<3 {
            render(GuideView(showImport: .constant(false), initialStep: step).frame(width: 400), name: "guide-\(step)", outDir: outDir)
        }
    }

    /// Renders through an offscreen NSHostingView so ScrollView, Charts and
    /// AppKit-backed views draw like they do on screen.
    private static func render<V: View>(_ view: V, name: String, outDir: String, scale: CGFloat = 2,
                                         size: CGSize? = nil, settle: TimeInterval = 0.3) {
        for scheme in [ColorScheme.dark, .light] {
            let content = view
                .environment(Monitor.shared)
                .environment(AppSettings.shared)
                .environment(PhoneSync.shared)
                .modifier(AppLanguageModifier())
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let fitting = size ?? host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: fitting),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            window.orderFrontRegardless()
            host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            window.setContentSize(host.frame.size)
            host.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(settle)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                fputs("Cannot render snapshot: \(name)\n", stderr)
                exit(1)
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
            do {
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    fputs("Cannot encode snapshot: \(name)\n", stderr)
                    exit(1)
                }
                try data.write(to: url)
            } catch {
                fputs("Cannot save snapshot: \(error)\n", stderr)
                exit(1)
            }
            print("wrote \(url.path)")
        }
    }

    private static func seedHistory(id: UUID) async {
        let now = Date()
        var sys = SystemStat()
        sys.memTotalKB = 100
        for i in stride(from: 24 * 60, through: 0, by: -2) {
            let t = now.addingTimeInterval(-Double(i) * 60)
            let h = Double(i) / 60
            // A training job that started 18h ago on 6 cards, with a gap.
            let running = h < 18 && !(h > 9 && h < 10.5)
            if h > 12.5 && h < 13.5 { continue } // app was closed
            sys.cpuUsage = running ? 0.4 + 0.05 * sin(h) : 0.03
            sys.memAvailableKB = running ? 50 : 95
            let gpus = (0..<8).map { g -> GPUStat in
                let on = running
                let u = on ? min(100, 88 + 10 * sin(h * 3 + Double(g))) : 0
                return GPUStat(index: g, uuid: "\(g)", name: "B200", utilization: u,
                               memoryUsedMiB: on ? 160_000 + Double(g) * 900 : 600, memoryTotalMiB: 184_320)
            }
            await Monitor.shared.history.record(server: id, snapshot: ServerSnapshot(system: sys, hasNvidiaSMI: true, gpus: gpus, tasks: []), at: t)
        }
    }

    private static func demoServers() -> [(ServerConfig, ServerState)] {
        DemoFleet.machines.map { m in
            (ServerConfig(name: m.name, target: m.name), ServerState(snapshot: m.snapshot, error: m.error))
        }
    }
}

/// Settings window content pinned to one page, for snapshots.
private struct SettingsPreview: View {
    var page: SettingsPage

    var body: some View {
        SettingsView(initialPage: page)
    }
}

/// `LastJobSection` opened once, for the snapshot.
private struct LastJobPreview: View {
    var jobs: TaskTracker
    @State private var opened = false

    var body: some View {
        LastJobSection(last: jobs.last, history: jobs.finished, initiallyExpanded: true)
    }
}
