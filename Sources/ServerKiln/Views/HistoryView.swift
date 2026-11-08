import Charts
import ServerKilnCore
import SwiftUI
import ServerKilnUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case tenMinutes, day, week, month

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tenMinutes: return String(appLocalized: "10 分钟")
        case .day: return String(appLocalized: "24 小时")
        case .week: return String(appLocalized: "7 天")
        case .month: return String(appLocalized: "30 天")
        }
    }
    var duration: TimeInterval {
        switch self {
        case .tenMinutes: return 10 * 60
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }
    /// Bucket size giving ~150–300 points per series.
    var bucket: TimeInterval {
        switch self {
        case .tenMinutes: return 5
        case .day: return 5 * 60
        case .week: return 30 * 60
        case .month: return 3 * 3600
        }
    }
}

/// Utilisation / VRAM curves per server, aggregated or per GPU.
struct HistoryView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @State private var serverID: UUID?
    @State private var range: HistoryRange = .day
    /// Bumps every few seconds in the 10-minute range to redraw live data.
    @State private var tick = 0
    @State private var perGPU: Bool

    /// Snapshot rendering can't run async loads, so points may be injected.
    private let preloaded: [HistoryPoint]?

    init(initialPerGPU: Bool = false, preloaded: [HistoryPoint]? = nil, initialRange: HistoryRange = .day) {
        _range = State(initialValue: initialRange)
        _perGPU = State(initialValue: initialPerGPU)
        _points = State(initialValue: preloaded ?? [])
        self.preloaded = preloaded
    }
    @State private var points: [HistoryPoint] = []
    @State private var loading = false

    private var server: ServerConfig? { settings.servers.first { $0.id == serverID } }
    private var isGPUServer: Bool { monitor.states[serverID ?? UUID()]?.snapshot?.isGPUServer ?? points.contains { $0.utilization != nil } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.5)
            content
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(VisualEffectBackground().ignoresSafeArea())
        .onAppear {
            serverID = monitor.historySelection ?? serverID ?? settings.servers.first?.id
            if CommandLine.arguments.contains("--stress-history") { stress() }
        }
        .onChange(of: monitor.historySelection) { _, new in if let new { serverID = new } }
        .task(id: "\(serverID?.uuidString ?? "")-\(range.rawValue)-\(perGPU)-\(tick)") { await load() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(String(appLocalized: "服务器")).padding(.horizontal, 8).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(settings.servers) { s in
                        let selected = s.id == serverID
                        Button {
                            serverID = s.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: monitor.states[s.id]?.snapshot?.isGPUServer == false ? "cpu" : "server.rack")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(s.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selected ? Color.primary.opacity(0.1) : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .padding(.top, 24)
        .frame(width: 180)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server?.name ?? String(appLocalized: "历史")).font(.system(size: 17, weight: .semibold))
                    Text(range == .tenMinutes ? String(appLocalized: "每 5 秒一个点 · 实时")
                         : String(appLocalized: "每分钟采样一次 · 保留最近 \(settings.historyRetentionDays) 天"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isGPUServer {
                    PillPicker(selection: $perGPU, options: [(false, String(appLocalized: "整体")), (true, String(appLocalized: "按卡"))])
                }
                PillPicker(selection: $range, options: HistoryRange.allCases.map { ($0, $0.title) })
            }

            if points.isEmpty {
                emptyState
            } else if perGPU && points.contains(where: { $0.gpu == nil }) {
                emptyState // stale aggregate data while per-GPU data loads
            } else if isGPUServer {
                chartCard(title: String(appLocalized: "GPU 利用率"), unit: "%") { utilChart }
                chartCard(title: String(appLocalized: "显存占用"), unit: perGPU ? "%" : "%") { memChart }
                if !perGPU { statsRow }
            } else {
                chartCard(title: "CPU", unit: "%") { hostChart(\.cpu) }
                chartCard(title: String(appLocalized: "内存"), unit: "%") { hostChart(\.ram) }
            }
        }
        .padding(20)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(loading ? "加载中…" : "还没有数据").font(.callout).foregroundStyle(.secondary)
            Text("ServerKiln 运行时会自动记录，几分钟后即可看到曲线").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chartCard<C: View>(title: String, unit: String, @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            chart()
                .frame(minHeight: 150)
        }
        .padding(12)
        .card()
    }

    private var xDomain: ClosedRange<Date> { Date().addingTimeInterval(-range.duration)...Date() }

    // Series are split wherever there's a gap (app not running / offline),
    // so lines don't bridge missing periods.
    private func segment(_ p: HistoryPoint) -> String {
        "\(p.gpu ?? -1)-\(Int(p.time.timeIntervalSince1970 / (range.bucket * 3)))"
    }

    private var segmented: [(HistoryPoint, Int)] {
        var out: [(HistoryPoint, Int)] = []
        var lastTime: [Int: Date] = [:]
        var seg: [Int: Int] = [:]
        var next = 0
        for p in points {
            let key = p.gpu ?? -1
            if let t = lastTime[key], p.time.timeIntervalSince(t) <= range.bucket * 2.5, let s = seg[key] {
                out.append((p, s))
            } else {
                seg[key] = next
                out.append((p, next))
                next += 1
            }
            lastTime[key] = p.time
        }
        return out
    }

    @ViewBuilder private var utilChart: some View {
        let data = segmented
        Chart {
            ForEach(data, id: \.0.id) { p, s in
                if let u = p.utilization {
                    if perGPU, let g = p.gpu {
                        LineMark(x: .value("时间", p.time), y: .value("利用率", u), series: .value("段", s))
                            .foregroundStyle(by: .value("GPU", "GPU \(g)"))
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                    } else if !perGPU {
                        AreaMark(x: .value("时间", p.time), y: .value("利用率", u), series: .value("段", s))
                            .foregroundStyle(heatGradient.opacity(0.3))
                            .alignsMarkStylesWithPlotArea()
                        LineMark(x: .value("时间", p.time), y: .value("利用率", u), series: .value("段", s))
                            .foregroundStyle(heatGradient)
                            .alignsMarkStylesWithPlotArea()
                            .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: xDomain)
        .chartYAxis { percentAxis }
        .chartXAxis { timeAxis }
        .chartLegend(perGPU ? .visible : .hidden)
        .chartForegroundStyleScale(domain: gpuNames, range: gpuNames.indices.map { Self.palette[$0 % Self.palette.count] })
    }

    @ViewBuilder private var memChart: some View {
        let data = segmented
        Chart {
            ForEach(data, id: \.0.id) { p, s in
                if let m = p.memoryFraction {
                    if perGPU, let g = p.gpu {
                        LineMark(x: .value("时间", p.time), y: .value("显存", m * 100), series: .value("段", s))
                            .foregroundStyle(by: .value("GPU", "GPU \(g)"))
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                    } else if !perGPU {
                        AreaMark(x: .value("时间", p.time), y: .value("显存", m * 100), series: .value("段", s))
                            .foregroundStyle(heatGradient.opacity(0.3))
                            .alignsMarkStylesWithPlotArea()
                        LineMark(x: .value("时间", p.time), y: .value("显存", m * 100), series: .value("段", s))
                            .foregroundStyle(heatGradient)
                            .alignsMarkStylesWithPlotArea()
                            .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: xDomain)
        .chartYAxis { percentAxis }
        .chartXAxis { timeAxis }
        .chartLegend(perGPU ? .visible : .hidden)
        .chartForegroundStyleScale(domain: gpuNames, range: gpuNames.indices.map { Self.palette[$0 % Self.palette.count] })
    }

    private func hostChart(_ key: KeyPath<HistoryPoint, Double?>) -> some View {
        let data = segmented
        return Chart {
            ForEach(data, id: \.0.id) { p, s in
                if let v = p[keyPath: key] {
                    AreaMark(x: .value("时间", p.time), y: .value("值", v * 100), series: .value("段", s))
                        .foregroundStyle(heatGradient.opacity(0.3))
                        .alignsMarkStylesWithPlotArea()
                    LineMark(x: .value("时间", p.time), y: .value("值", v * 100), series: .value("段", s))
                        .foregroundStyle(heatGradient)
                        .alignsMarkStylesWithPlotArea()
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: xDomain)
        .chartYAxis { percentAxis }
        .chartXAxis { timeAxis }
    }

    private var gpuNames: [String] {
        Array(Set(points.compactMap(\.gpu))).sorted().map { "GPU \($0)" }
    }

    /// Distinct hues for up to 16 cards.
    static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .yellow, .red,
        .indigo, .mint, .brown, .cyan, Color(hue: 0.9, saturation: 0.5, brightness: 0.9),
        Color(hue: 0.15, saturation: 0.6, brightness: 0.6), .gray, Color(hue: 0.55, saturation: 0.9, brightness: 0.5),
    ]

    /// Vertical heat gradient so higher values read redder.
    private var heatGradient: LinearGradient {
        LinearGradient(stops: [
            .init(color: Theme.heat(0), location: 0),
            .init(color: Theme.heat(0.5), location: 0.5),
            .init(color: Theme.heat(1), location: 1),
        ], startPoint: .bottom, endPoint: .top)
    }

    private var percentAxis: some AxisContent {
        AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
            AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
            AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.system(size: 9)) }
        }
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) { v in
            AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
            AxisValueLabel {
                if let d = v.as(Date.self) {
                    Text(range == .tenMinutes ? d.formatted(.dateTime.hour().minute())
                        : range == .day ? d.formatted(date: .omitted, time: .shortened)
                        : d.formatted(.dateTime.month(.defaultDigits).day()))
                        .font(.system(size: 9))
                }
            }
        }
    }

    private var statsRow: some View {
        let utils = points.compactMap(\.utilization)
        let mems = points.compactMap(\.memoryFraction)
        let busyShare = utils.isEmpty ? 0 : Double(utils.filter { $0 >= settings.utilizationThreshold }.count) / Double(utils.count)
        return HStack(spacing: 10) {
            stat(String(appLocalized: "平均利用率"), utils.isEmpty ? "—" : "\(Int(utils.reduce(0, +) / Double(utils.count)))%", utils.isEmpty ? 0 : utils.reduce(0, +) / Double(utils.count) / 100)
            stat(String(appLocalized: "峰值显存"), mems.max().map { Format.percent($0) } ?? "—", mems.max() ?? 0)
            stat(String(appLocalized: "忙碌时间占比"), Format.percent(busyShare), busyShare)
        }
    }

    private func stat(_ title: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.heat(fraction))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .card()
    }

    /// Debug: cycles servers / modes / ranges quickly to shake out crashes.
    private func stress() {
        Task { @MainActor in
            for i in 0..<60 {
                try? await Task.sleep(for: .milliseconds(150))
                switch i % 3 {
                case 0: perGPU.toggle()
                case 1: range = HistoryRange.allCases[(i / 3) % HistoryRange.allCases.count]
                default: serverID = settings.servers[(i / 3) % max(1, settings.servers.count)].id
                }
            }
            print("stress-history done")
            exit(0)
        }
    }

    private func load() async {
        guard preloaded == nil else { return }
        guard let id = serverID else {
            points = []
            return
        }
        loading = true
        if perGPU != (points.first?.gpu != nil) { points = [] }
        let since = Date().addingTimeInterval(-range.duration)
        if range == .tenMinutes {
            // Live polls from memory, refreshed while the range is shown.
            points = monitor.recent.points(id, perGPU: perGPU, since: since)
            loading = false
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, range == .tenMinutes { tick += 1 }
            return
        }
        points = await monitor.history.query(server: id, since: since, bucket: range.bucket, perGPU: perGPU)
        loading = false
    }
}
