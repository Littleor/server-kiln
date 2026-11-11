import ServerKilnCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum Theme {
    /// The single colour scale used for every load metric (GPU utilisation,
    /// VRAM, busy counts, CPU): green → yellow → orange → red.
    public static func heat(_ fraction: Double) -> Color {
        let x = min(1, max(0, fraction))
        let hue = 0.36 * (1 - x)
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hue: hue, saturation: dark ? 0.72 : 0.86, brightness: dark ? 0.92 : 0.78, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            return UIColor(hue: hue, saturation: dark ? 0.72 : 0.86, brightness: dark ? 0.92 : 0.78, alpha: 1)
        })
        #endif
    }

    /// Heat for "busy of total" counts; nothing busy reads as neutral grey.
    public static func occupancy(_ busy: Int, of total: Int) -> Color {
        guard busy > 0, total > 0 else { return idle }
        return heat(Double(busy) / Double(total))
    }

    public static let idle = Color.secondary.opacity(0.55)
    public static let track = Color.primary.opacity(0.08)
    public static let offline = Color.red
    public static let cpuOnly = Color.blue
}


/// The rounded card surface shared by the panel and the settings window.
public struct CardBackground: ViewModifier {
    public var highlighted = false
    public var radius: CGFloat = 10

    public init(highlighted: Bool = false, radius: CGFloat = 10) {
        self.highlighted = highlighted
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }

    /// Mac: translucent over the panel material. iOS: solid cards on the
    /// grouped background, like Settings.
    private var fill: Color {
        #if os(macOS)
        Color.primary.opacity(highlighted ? 0.075 : 0.045)
        #else
        Color(uiColor: highlighted ? .tertiarySystemGroupedBackground : .secondarySystemGroupedBackground)
        #endif
    }
}

public extension View {
    func card(highlighted: Bool = false, radius: CGFloat = 10) -> some View {
        modifier(CardBackground(highlighted: highlighted, radius: radius))
    }
}

/// Small uppercase section caption.
public struct SectionTitle: View {
    var text: String
    var trailing: String?

    public init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(text)
            if let trailing { Text(trailing).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .lineLimit(1)
    }
}


// MARK: - Indicators

/// Connection state only — GPU load is shown by `OccupancyBadge`.
public enum ConnectionStatus {
    case online, offline, connecting

    public var color: Color {
        switch self {
        case .online: return .green
        case .offline: return Theme.offline
        case .connecting: return Color.secondary.opacity(0.45)
        }
    }

    public var label: String {
        switch self {
        case .online: return String(appLocalized: "已连接")
        case .offline: return String(appLocalized: "离线")
        case .connecting: return String(appLocalized: "连接中")
        }
    }
}

/// Connection status dot.
public struct StatusDot: View {
    public var status: ConnectionStatus

    public init(status: ConnectionStatus) { self.status = status }

    public var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 7, height: 7)
            .frame(width: 12, height: 12)
            .help(status.label)
    }
}

/// "6/8" capsule tinted by occupancy.
public struct OccupancyBadge: View {
    public var busy: Int
    public var total: Int

    public init(busy: Int, total: Int) {
        self.busy = busy
        self.total = total
    }

    public var body: some View {
        let color = Theme.occupancy(busy, of: total)
        Text(verbatim: "\(busy)/\(total)")
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .fixedSize()
            .foregroundStyle(busy > 0 ? color : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(busy > 0 ? color.opacity(0.16) : Theme.track))
    }
}

/// Thin horizontal capsule meter.
public struct Meter: View {
    public var fraction: Double
    public var color: Color
    public var height: CGFloat = 4

    public init(fraction: Double, color: Color, height: CGFloat = 4) {
        self.fraction = fraction
        self.color = color
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: fraction > 0 ? max(height, geo.size.width * min(1, fraction)) : 0)
            }
        }
        .frame(height: height)
    }
}

/// A taller bar with its value printed inside, used in the GPU detail rows.
public struct ValueBar: View {
    public var fraction: Double
    public var color: Color
    public var text: String
    public var height: CGFloat = 18

    public init(fraction: Double, color: Color, text: String, height: CGFloat = 18) {
        self.fraction = fraction
        self.color = color
        self.text = text
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.track)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.55))
                    .frame(width: fraction > 0 ? max(4, geo.size.width * min(1, fraction)) : 0)
                Text(text)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
        }
        .frame(height: height)
    }
}

/// One column per GPU: the tall bar is utilisation, the short bar under it is
/// VRAM usage (its fill width = memory fraction). Both use the heat scale.
public struct GPUMiniBars: View {
    public var gpus: [GPUStat]
    /// Height of the utilisation columns; the VRAM strip sits underneath.
    public var barHeight: CGFloat
    public var maxWidth: CGFloat

    public init(gpus: [GPUStat], barHeight: CGFloat = 24, maxWidth: CGFloat = 85) {
        self.gpus = gpus
        self.barHeight = barHeight
        self.maxWidth = maxWidth
    }

    public var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = gpus.count > 8 ? 1.5 : 3
            let count = CGFloat(max(1, gpus.count))
            let width = max(1, (geo.size.width - spacing * (count - 1)) / count)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(gpus) { gpu in
                    VStack(spacing: 2.5) {
                        let util = gpu.utilization / 100
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.heat(util))
                                .frame(height: util > 0 ? max(2, barHeight * util) : 0)
                        }
                        .frame(width: width, height: barHeight)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule()
                                .fill(Theme.heat(gpu.memoryFraction))
                                .frame(width: gpu.memoryFraction > 0.005 ? max(1.5, width * gpu.memoryFraction) : 0)
                        }
                        .frame(width: width, height: 3)
                    }
                    .help(String(appLocalized: "GPU \(gpu.index) · 利用率 \(Int(gpu.utilization))% · 显存 \(Format.mib(gpu.memoryUsedMiB))/\(Format.mib(gpu.memoryTotalMiB))"))
                }
            }
        }
        // Keep room for the summary metrics even on 16-GPU hosts.
        .frame(width: min(maxWidth, CGFloat(max(1, gpus.count)) * 11 - 3), height: barHeight + 5.5)
    }
}

/// Right-side summary for CPU-only servers, styled like `GPUMiniBars`: one
/// column each for CPU and memory, tall bar = usage on the heat scale, with a
/// short caption underneath.
public struct HostMiniBars: View {
    public var cpu: Double?
    public var memory: Double?

    public init(cpu: Double?, memory: Double?) {
        self.cpu = cpu
        self.memory = memory
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            column("CPU", cpu)
            column("MEM", memory)
        }
    }

    private func column(_ label: String, _ value: Double?) -> some View {
        let v = min(1, max(0, value ?? 0))
        return HStack(alignment: .bottom, spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.heat(v))
                    .frame(height: v > 0 ? max(2, 24 * v) : 0)
            }
            .frame(width: 8, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? Color.secondary : Theme.heat(v))
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 30, alignment: .leading)
            .lineLimit(1)
        }
        .help("\(label == "CPU" ? "CPU" : String(appLocalized: "内存")) \(value.map { Format.percent($0) } ?? "—")")
    }
}


// MARK: - Controls

/// ⓘ that reveals details on click / tap, so rows stay one line instead of
/// carrying subtitle text. Hover only highlights it.
public struct InfoButton: View {
    public var text: String
    public var size: CGFloat
    public var symbol: String
    /// Fixed colour for warnings; plain info dims until hovered.
    public var tint: Color?
    @State private var shown = false
    @State private var hovering = false

    public init(text: String, size: CGFloat = 11, symbol: String = "info.circle", tint: Color? = nil) {
        self.text = text
        self.size = size
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? (hovering || shown ? Color.primary : Color.secondary.opacity(0.7)))
                .padding(4)
                .contentShape(Rectangle())
                .padding(-4)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
                #if os(iOS)
                .presentationCompactAdaptation(.popover)
                #endif
        }
    }
}

/// Capsule text button, optionally prominent.
public struct PillButtonStyle: ButtonStyle {
    public var prominent = false
    public var destructive = false
    /// Fill for prominent pills; the system accent colour by default.
    public var fill: Color?

    public init(prominent: Bool = false, destructive: Bool = false, fill: Color? = nil) {
        self.prominent = prominent
        self.destructive = destructive
        self.fill = fill
    }

    public func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, destructive: destructive, fill: fill)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let prominent: Bool
        let destructive: Bool
        let fill: Color?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : destructive ? Color.red : Color.primary)
            .background(
                Capsule().fill(
                    prominent ? (fill ?? Color.accentColor).opacity(configuration.isPressed ? 0.75 : 1)
                        : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)
                )
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// Segmented control drawn in the panel's visual language.
public struct PillPicker<Value: Hashable>: View {
    @Binding public var selection: Value
    public var options: [(Value, String)]

    public init(selection: Binding<Value>, options: [(Value, String)]) {
        _selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let selected = value == selection
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = value }
                } label: {
                    Text(label)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.track.opacity(0.7)))
    }
}

/// Compact switch that renders identically everywhere.
public struct CapsuleToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: 30, height: 17)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .frame(width: 13, height: 13)
                    .padding(2)
            }
            .onTapGesture {
                withAnimation(.snappy(duration: 0.18)) { configuration.isOn.toggle() }
            }
        }
    }
}


// MARK: - Server rows

/// `↓ 1.2M  ↑ 80K` network throughput, bytes per second.
public struct NetRate: View {
    public var rx: Double?
    public var tx: Double?

    public init(rx: Double?, tx: Double?) {
        self.rx = rx
        self.tx = tx
    }

    public var body: some View {
        HStack(spacing: 6) {
            item("arrow.down", rx)
            item("arrow.up", tx)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(String(appLocalized: "网络 下行 \(Format.rate(rx))/s · 上行 \(Format.rate(tx))/s"))
    }

    private func item(_ symbol: String, _ value: Double?) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(value == nil ? "…" : Format.rate(value))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
        }
    }
}


/// `[idx] [VRAM bar] [utilisation bar]  temp · power` — VRAM on the left,
/// utilisation on the right, both on the heat scale.
public struct GPURow: View {
    public var gpu: GPUStat
    public var busy: Bool
    public var showName: Bool

    public init(gpu: GPUStat, busy: Bool, showName: Bool) {
        self.gpu = gpu
        self.busy = busy
        self.showName = showName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showName {
                Text(gpu.name).font(.system(size: 9)).foregroundStyle(.secondary).padding(.leading, 26)
            }
            HStack(spacing: 6) {
                Text(verbatim: "\(gpu.index)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(busy ? Color.primary : Color.secondary)
                    .frame(width: 20, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.track))
                ValueBar(
                    fraction: gpu.memoryFraction,
                    color: Theme.heat(gpu.memoryFraction),
                    text: "\(Format.mib(gpu.memoryUsedMiB)) / \(Format.mib(gpu.memoryTotalMiB))"
                )
                ValueBar(
                    fraction: gpu.utilization / 100,
                    color: Theme.heat(gpu.utilization / 100),
                    text: "\(Int(gpu.utilization))%"
                )
                .frame(width: 92)
                VStack(alignment: .trailing, spacing: 0) {
                    if let t = gpu.temperature {
                        Text(verbatim: "\(Int(t))°C").foregroundStyle(t >= 80 ? Color.orange : Color.secondary)
                    }
                    if let p = gpu.powerDraw {
                        Text(verbatim: "\(Int(p))W").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 9).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
            }
        }
        .help("GPU \(gpu.index) · \(gpu.name)" + (gpu.powerLimit.map { String(appLocalized: " · 功耗上限 \(Int($0))W") } ?? ""))
    }
}


public struct SystemGrid: View {
    public var sys: SystemStat

    public init(sys: SystemStat) { self.sys = sys }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("CPU", Format.percent(sys.cpuUsage) + (sys.cpuCores.map { String(appLocalized: " · \($0) 核") } ?? ""), fraction: sys.cpuUsage)
            row(String(appLocalized: "内存"), "\(Format.kb(sys.memTotalKB.flatMap { t in sys.memAvailableKB.map { t - $0 } })) / \(Format.kb(sys.memTotalKB))", fraction: sys.memFraction)
            row(String(appLocalized: "磁盘 /"), "\(Format.kb(sys.diskUsedKB)) / \(Format.kb(sys.diskTotalKB))", fraction: sys.diskFraction)
            HStack {
                Text("网络").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Text("↓ \(Format.rate(sys.netRxRate))/s   ↑ \(Format.rate(sys.netTxRate))/s")
                Spacer()
            }
            HStack {
                Text("负载").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Text(sys.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                Spacer()
                Text("运行 \(Format.duration(sys.uptimeSeconds))").foregroundStyle(.secondary)
            }
            if !sys.os.isEmpty || !sys.hostname.isEmpty {
                Text([sys.hostname, sys.os].filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
    }

    private func row(_ title: String, _ value: String, fraction: Double?) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Meter(fraction: fraction ?? 0, color: Theme.heat(fraction ?? 0))
            Text(value).frame(minWidth: 96, alignment: .trailing)
        }
    }
}



// MARK: - Panel pieces shared with iOS and widgets

/// One of the three equal-width summary tiles at the top of the panel.
public struct SummaryTile<Bar: View>: View {
    public var value: Int
    public var total: Int
    public var label: String
    public var color: Color
    public var scale: CGFloat
    public var bar: Bar

    public init(value: Int, total: Int, label: String, color: Color, scale: CGFloat = 1, @ViewBuilder bar: () -> Bar) {
        self.value = value
        self.total = total
        self.label = label
        self.color = color
        self.scale = scale
        self.bar = bar()
    }

    public var body: some View {
        VStack(spacing: 5 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: "\(value)")
                    .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(value > 0 ? color : Color.secondary)
                Text(verbatim: "/\(total)")
                    .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .monospacedDigit()
            bar.frame(width: 56 * scale)
            Text(label)
                .font(.system(size: 10 * scale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10 * scale)
        .card(radius: 10 * scale)
    }
}

/// Fleet totals shown by the summary tiles.
public struct FleetSummary: Equatable, Sendable {
    public var busyServers = 0, gpuServers = 0, busyGPUs = 0, totalGPUs = 0, online = 0, offline = 0, total = 0
    public init() {}
}

/// The panel's three summary tiles.
public struct SummaryTiles: View {
    public var summary: FleetSummary
    public var scale: CGFloat
    public var spacing: CGFloat

    public init(_ summary: FleetSummary, scale: CGFloat = 1, spacing: CGFloat = 8) {
        self.summary = summary
        self.scale = scale
        self.spacing = spacing
    }

    public var body: some View {
        let s = summary
        HStack(spacing: spacing) {
            SummaryTile(value: s.busyServers, total: s.gpuServers, label: String(appLocalized: "服务器训练中"),
                        color: Theme.occupancy(s.busyServers, of: s.gpuServers), scale: scale) {
                Meter(fraction: s.gpuServers > 0 ? Double(s.busyServers) / Double(s.gpuServers) : 0,
                      color: Theme.occupancy(s.busyServers, of: s.gpuServers), height: 3 * scale)
            }
            SummaryTile(value: s.busyGPUs, total: s.totalGPUs, label: String(appLocalized: "GPU 使用中"),
                        color: Theme.occupancy(s.busyGPUs, of: s.totalGPUs), scale: scale) {
                Meter(fraction: s.totalGPUs > 0 ? Double(s.busyGPUs) / Double(s.totalGPUs) : 0,
                      color: Theme.occupancy(s.busyGPUs, of: s.totalGPUs), height: 3 * scale)
            }
            SummaryTile(value: s.online, total: s.total, label: s.offline > 0 ? String(appLocalized: "在线 · \(s.offline) 离线") : String(appLocalized: "服务器在线"),
                        color: .primary, scale: scale) {
                HStack(spacing: 2) {
                    ForEach(0..<max(1, s.total), id: \.self) { i in
                        Capsule()
                            .fill(s.total == 0 ? Theme.track : i < s.online ? Color.green.opacity(0.8)
                                : i < s.online + s.offline ? Theme.offline : Theme.track)
                            .frame(height: 3 * scale)
                    }
                }
            }
        }
    }
}

// MARK: - Job history and processes

/// "上一条任务", collapsed by default: what last ran, and from when to when.
public struct LastJobSection: View {
    public var last: TaskRecord?
    public var history: [TaskRecord]
    @State private var expanded = false

    public init(last: TaskRecord?, history: [TaskRecord], initiallyExpanded: Bool = false) {
        self.last = last
        self.history = history
        _expanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        if let last {
            VStack(alignment: .leading, spacing: 7) {
                Button {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        SectionTitle(String(appLocalized: "上一条任务"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer(minLength: 6)
                        // Collapsed summary: name and when it ended.
                        if !expanded {
                            Text(Self.short(last.command))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(last.endedAt.map { Self.ago($0) } ?? "")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(spacing: 5) {
                        ForEach(history.prefix(5)) { JobRow(job: $0) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.identity)
                }
            }
        }
    }

    static func short(_ command: String) -> String {
        var parts = command.split(separator: " ").map(String.init)
        if let first = parts.first, first.contains("/") { parts[0] = String(first.split(separator: "/").last ?? "") }
        return parts.joined(separator: " ")
    }

    static func ago(_ date: Date) -> String {
        String(appLocalized: "\(Format.duration(Date().timeIntervalSince(date)))前结束")
    }
}

/// One finished job: command, start → end, duration, GPUs.
struct JobRow: View {
    var job: TaskRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.command)
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Label {
                    Text(Self.range(job)).monospacedDigit()
                } icon: { Image(systemName: "clock") }
                Text(Format.duration(job.duration)).monospacedDigit()
                if !job.gpuIndices.isEmpty {
                    Text("GPU " + job.gpuIndices.map(String.init).joined(separator: ","))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let cwd = job.cwd {
                Text(cwd).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    /// "11/03 14:20 → 11/04 09:41", dropping the day when it's the same.
    static func range(_ job: TaskRecord) -> String {
        let cal = Calendar.current
        let start = job.startedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
        guard let end = job.endedAt else { return start }
        let endText = cal.isDate(end, inSameDayAs: job.startedAt)
            ? end.formatted(.dateTime.hour().minute())
            : end.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
        return "\(start) → \(endText)"
    }
}

/// Top processes by CPU or memory (CPU servers, or containers where the GPU
/// can't see its processes).
public struct ProcessSection: View {
    public var processes: [GPUTask]
    public var memTotalKB: Double?
    /// `ps` reports 100% per core; meters are relative to the whole host.
    public var cores: Int?
    private var initiallyExpandedProcess: Bool
    @State private var byMemory = false
    @State private var expanded = true

    public init(processes: [GPUTask], memTotalKB: Double?, cores: Int? = nil, initiallyExpandedProcess: Bool = false) {
        self.initiallyExpandedProcess = initiallyExpandedProcess
        self.processes = processes
        self.memTotalKB = memTotalKB
        self.cores = cores
    }

    public var body: some View {
        let sorted = processes.sorted {
            byMemory ? ($0.rssKB ?? 0) > ($1.rssKB ?? 0) : ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0)
        }.prefix(6)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        SectionTitle(String(appLocalized: "进程"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if expanded {
                    PillPicker(selection: $byMemory, options: [(false, "CPU"), (true, String(appLocalized: "内存"))])
                        .scaleEffect(0.85, anchor: .trailing)
                }
            }
            if expanded {
                VStack(spacing: 3) {
                    ForEach(Array(sorted)) { p in
                        ProcessRow(expanded: initiallyExpandedProcess && p.id == sorted.first?.id, process: p, byMemory: byMemory, memTotalKB: memTotalKB, cores: cores)
                    }
                }
            }
        }
    }
}

struct ProcessRow: View {
    @State var expanded = false
    var process: GPUTask
    var byMemory: Bool
    var memTotalKB: Double?
    var cores: Int?

    var body: some View {
        let cpu = (process.cpuPercent ?? 0) / 100 / Double(max(1, cores ?? 1))
        let mem = memTotalKB.map { (process.rssKB ?? 0) / max(1, $0) } ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8))
                    Text(LastJobSection.short(process.command))
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(process.command)
                    Text(process.user).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1).frame(width: 44, alignment: .trailing)
                    // The sort key gets the meter; the other value is plain text.
                    if byMemory {
                        Text(String(format: "%.0f%%", process.cpuPercent ?? 0)).lineLimit(1).minimumScaleFactor(0.75).frame(width: 48, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Meter(fraction: mem, color: Theme.heat(mem), height: 4).frame(width: 40)
                        Text(Format.kb(process.rssKB)).frame(width: 40, alignment: .trailing)
                    } else {
                        Meter(fraction: min(1, cpu), color: Theme.heat(min(1, cpu)), height: 4).frame(width: 40)
                        Text(String(format: "%.0f%%", process.cpuPercent ?? 0)).lineLimit(1).minimumScaleFactor(0.75).frame(width: 48, alignment: .trailing)
                        Text(Format.kb(process.rssKB)).frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10).monospacedDigit())
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    Text(process.command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text("PID " + String(process.pid))
                        Label(process.user, systemImage: "person")
                        Label(Format.duration(process.elapsedSeconds.map(Double.init)), systemImage: "timer")
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text("CPU " + (process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"))
                        Text(String(appLocalized: "内存") + " " + Format.kb(process.rssKB))
                        if memTotalKB != nil, process.rssKB != nil {
                            Text(String(format: "%.1f%%", mem * 100))
                        }
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    if let cwd = process.cwd {
                        Text(cwd).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ProcessCopyButtons(command: process.command, pid: process.pid)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.04)))
            }
        }
        .font(.caption)
    }
}


// Shared with task details so both surfaces use identical copy actions.
public struct ProcessCopyButtons: View {
    public var command: String
    public var pid: Int

    public init(command: String, pid: Int) {
        self.command = command
        self.pid = pid
    }

    public var body: some View {
        HStack {
            Spacer()
            Button { copy(command) } label: {
                Label(String(appLocalized: "复制命令"), systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("copy-command")
            Button { copy(String(pid)) } label: {
                Label(String(appLocalized: "复制 PID"), systemImage: "number")
            }
            .accessibilityIdentifier("copy-pid")
        }
        .buttonStyle(PillButtonStyle())
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
