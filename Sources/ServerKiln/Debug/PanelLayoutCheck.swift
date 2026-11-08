import AppKit
import ServerKilnCore
import SwiftUI
import ServerKilnUI

/// Runs against actual AppKit-hosted SwiftUI views with isolated snapshot data:
/// `ServerKiln --snapshot /tmp/serverkiln-layout --check-layout`.
@MainActor
enum PanelLayoutCheck {
    static func run() {
        let settings = AppSettings.shared
        let monitor = Monitor.shared
        settings.finishedGuide = true
        let server = ServerConfig(name: "training-server-with-a-long-name", target: "user@a-very-long-server-hostname.example.com")
        settings.servers = [server]
        let card = NSHostingView(rootView: ServerCard(server: server, isExpanded: false, toggle: {})
            .environment(settings).environment(monitor).environment(PhoneSync.shared).frame(width: 380))
        let window = mount(card)
        defer { window.close() }
        let baseline = measure(card)
        var cases = 0
        for count in [0, 1, 8, 16] {
            for value in [Double?.none, 0, 0.09, 0.99, 1] {
                for rate in [Double?.none, 999, 1023, 1_024_000, 999_999_999] {
                    var sys = SystemStat()
                    sys.cpuUsage = value
                    sys.memTotalKB = 100
                    sys.memAvailableKB = value.map { (1 - $0) * 100 }
                    sys.netRxRate = rate
                    sys.netTxRate = rate
                    let gpus = (0..<count).map { GPUStat(index: $0, uuid: "\($0)", name: "NVIDIA RTX PRO 6000 Blackwell Server Edition",
                                                       utilization: (value ?? 0) * 100, memoryUsedMiB: 99_999, memoryTotalMiB: 100_000) }
                    monitor.inject(server.id, ServerState(snapshot: ServerSnapshot(system: sys, hasNvidiaSMI: count > 0, gpus: gpus, tasks: [])))
                    requireSameSize(measure(card), baseline, "\(count) GPUs, value \(String(describing: value)), rate \(String(describing: rate))")
                    cases += 1
                }
            }
        }
        for error in ["连接超时", String(repeating: "Connection refused by server. ", count: 10)] {
            monitor.inject(server.id, ServerState(error: error))
            requireSameSize(measure(card), baseline, "offline")
            cases += 1
        }
        print("PASS: \(cases) live summary updates preserve \(baseline.width) × \(baseline.height) pt (including connecting/offline).")

        SnapshotRenderer.openFirstTask = 42
        let detail = NSHostingView(rootView: ServerCard(server: server, isExpanded: true, toggle: {})
            .environment(settings).environment(monitor).environment(PhoneSync.shared).frame(width: 380))
        let detailWindow = mount(detail)
        var detailBaseline: CGSize?
        for elapsed in [59, 60, 3599, 3600, 86399, 86400, 8_639_999] {
            var sys = SystemStat()
            sys.cpuUsage = elapsed == 59 ? 0.09 : 1
            sys.cpuCores = 128
            sys.load = elapsed == 59 ? [0, 0, 0] : [1000.12, 999.99, 100.01]
            sys.netRxRate = Double(elapsed) * 1024
            sys.netTxRate = Double(elapsed) * 1024
            sys.uptimeSeconds = Double(elapsed)
            let task = GPUTask(pid: 42, user: "a-long-user-name", elapsedSeconds: elapsed,
                               command: "python train.py --config configs/training.yaml", gpuIndices: Array(0..<8),
                               memoryMiB: Double(elapsed), cpuPercent: 1000, rssKB: 1_000_000)
            monitor.inject(server.id, ServerState(snapshot: ServerSnapshot(system: sys, hasNvidiaSMI: false, gpus: [], tasks: [task])))
            let size = measure(detail)
            if let detailBaseline { requireSameSize(size, detailBaseline, "expanded task duration \(elapsed)") }
            else { detailBaseline = size }
        }
        detailWindow.close()
        SnapshotRenderer.openFirstTask = nil
        print("PASS: expanded task and system metrics retain their height across duration, load and bandwidth boundaries.")

        // History must claim its full height before the following section.
        let jobs = (0..<5).map { i in
            TaskRecord(command: String(repeating: "python train.py --config long-path/config.yaml ", count: 4),
                       user: "tester", cwd: "/project/training", gpuIndices: [0, 1],
                       startedAt: Date().addingTimeInterval(-3600), endedAt: Date().addingTimeInterval(-Double(i)))
        }
        var historyHeights: [CGFloat] = []
        for expanded in [false, true] {
            let host = NSHostingView(rootView: VStack(spacing: 14) {
                LastJobSection(last: jobs.first, history: jobs, initiallyExpanded: expanded)
                Text("System section below history")
            }.frame(width: 356))
            let historyWindow = mount(host)
            historyHeights.append(measure(host).height)
            historyWindow.close()
        }
        precondition(historyHeights[1] > historyHeights[0] + 250, "Expanded history collapsed into adjacent content")
        print("PASS: five expanded history rows reserve their height before the system section.")

        // Exercise the real scroll view, including the system's legacy scroller
        // preference, with short, overflowing and expanded content.
        for style in [NSScroller.Style.legacy, .overlay] {
            for count in [1, 12] {
                let servers = (0..<count).map { ServerConfig(name: "server-\($0)", target: "server-\($0)") }
                settings.servers = servers
                for item in servers { monitor.inject(item.id, ServerState(error: "Connection timed out")) }
                for expanded in [false, true, false] {
                    let panel = NSHostingView(rootView: PanelView(initiallyExpanded: expanded ? [servers[0].id] : [])
                        .environment(settings).environment(monitor).environment(PhoneSync.shared))
                    let panelWindow = mount(panel)
                    let size = measure(panel)
                    precondition(abs(size.width - 400) < 0.5, "Panel width changed: \(size)")
                    guard let scroll = descendants(panel).compactMap({ $0 as? NSScrollView }).first else {
                        preconditionFailure("Panel is not testing a real NSScrollView")
                    }
                    scroll.scrollerStyle = style
                    panel.layoutSubtreeIfNeeded()
                    precondition(!scroll.hasVerticalScroller && !scroll.hasHorizontalScroller, "Scrollbars must stay hidden")
                    precondition(abs(scroll.contentView.bounds.width - 400) < 0.5, "Scroller consumed content width")
                    if count == 12 {
                        precondition(scroll.documentView!.bounds.height > scroll.contentView.bounds.height, "Missing overflow")
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: 40))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        precondition(scroll.contentView.bounds.minY > 0, "Hidden scrollers disabled scrolling")
                    }
                    panelWindow.close()
                }
            }
        }
        precondition(BrandMark.menuBarImage.size == BrandMark.menuBarAlertImage.size)
        print("PASS: panel stays 400 pt wide; legacy/overlay scrollers are hidden; overflowing content still scrolls; badge canvas is stable.")
    }

    private static func mount<V: View>(_ host: NSHostingView<V>) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        return window
    }

    private static func measure<V: View>(_ host: NSHostingView<V>) -> CGSize {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        let size = host.fittingSize
        host.frame.size = size
        host.window?.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func requireSameSize(_ actual: CGSize, _ expected: CGSize, _ label: String) {
        precondition(abs(actual.width - expected.width) < 0.5 && abs(actual.height - expected.height) < 0.5,
                     "Layout jumped for \(label): \(expected) → \(actual)")
    }
}
