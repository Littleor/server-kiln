import ServerKilnCore
import SwiftUI
import ServerKilnUI

struct ServerCard: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    var server: ServerConfig
    var isExpanded: Bool
    var toggle: () -> Void
    @State private var hovering = false

    private var state: ServerState? { monitor.states[server.id] }
    private var snap: ServerSnapshot? { state?.snapshot }
    private var activity: ServerActivity? { monitor.activity(server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
            if isExpanded {
                Divider().padding(.horizontal, 12).opacity(0.6)
                ServerDetail(server: server)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
        }
        .card(highlighted: hovering || isExpanded)
        .onHover { hovering = $0 }
    }

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(status: monitor.connection(server))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let snap, snap.isGPUServer {
                        OccupancyBadge(busy: settings.busyPolicy.busyCount(snap), total: snap.gpus.count)
                    }
                    if state == nil {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(height: 18, alignment: .leading)
                secondaryLine
                    .lineLimit(1)
                    .frame(height: 14, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 6)
            if let snap, snap.isGPUServer {
                GPUMiniBars(gpus: snap.gpus)
            } else if let sys = snap?.system {
                HostMiniBars(cpu: sys.cpuUsage, memory: sys.memFraction)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .lineLimit(1)
        .frame(height: 35)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var secondaryLine: some View {
        if let error = state?.error {
            Text(error).font(.caption2).foregroundStyle(.red.opacity(0.85)).lineLimit(1)
        } else if let sys = snap?.system {
            HStack(spacing: 6) {
                metric("CPU", Format.percent(sys.cpuUsage))
                metric("MEM", Format.percent(sys.memFraction))
                NetRate(rx: sys.netRxRate, tx: sys.netTxRate)
            }
        } else {
            Text("正在连接 \(server.target)…").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// `CPU 42%` — a tiny caps label followed by the value; no glyphs.
    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Detail

struct ServerDetail: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    var server: ServerConfig
    @State private var tasksExpanded = true
    @State private var openTask: Int? = SnapshotRenderer.openFirstTask

    var body: some View {
        let state = monitor.states[server.id]
        VStack(alignment: .leading, spacing: 14) {
            if let error = state?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let snap = state?.snapshot {
                if snap.isGPUServer {
                    gpuSection(snap)
                } else if let err = snap.gpuError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
                // CPU servers have no GPU tasks: the process list replaces them.
                if snap.isGPUServer || !snap.tasks.isEmpty || snap.processes.isEmpty {
                    taskSection(snap)
                }
                LastJobSection(last: monitor.jobs[server.id]?.last, history: monitor.jobs[server.id]?.finished ?? [])
                if !snap.processes.isEmpty, !snap.isGPUServer || snap.tasks.allSatisfy({ $0.gpuIndices.isEmpty }) {
                    ProcessSection(processes: snap.processes, memTotalKB: snap.system.memTotalKB, cores: snap.system.cpuCores)
                }
                VStack(alignment: .leading, spacing: 7) {
                    SectionTitle(String(appLocalized: "系统"))
                    SystemGrid(sys: snap.system)
                }
            }
            HStack(spacing: 4) {
                Text(server.target).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).help(server.target)
                Spacer()
                Button {
                    monitor.historySelection = server.id
                    openWindow(id: "history")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("历史", systemImage: "chart.xyaxis.line") }
                Button {
                    copy("ssh \(server.port.map { "-p \($0) " } ?? "")\(server.target)")
                } label: { Label("复制 ssh", systemImage: "terminal") }
            }
            .buttonStyle(IconButtonStyle())
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .lineLimit(1)
        }
    }

    private func gpuSection(_ snap: ServerSnapshot) -> some View {
        let names = Set(snap.gpus.map(\.name))
        let model = names.count == 1 ? "\(names.first!) × \(snap.gpus.count)" : nil
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle("GPU", trailing: model)
                Spacer()
                legend
            }
            VStack(spacing: 5) {
                ForEach(snap.gpus) { gpu in
                    GPURow(gpu: gpu, busy: settings.busyPolicy.isBusy(gpu), showName: names.count > 1)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Text("显存")
            Text("利用率")
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder private func taskSection(_ snap: ServerSnapshot) -> some View {
        let gpuTasks = snap.tasks.contains { !$0.gpuIndices.isEmpty }
        VStack(alignment: .leading, spacing: 7) {
            Button {
                tasksExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    SectionTitle(gpuTasks || snap.tasks.isEmpty ? String(appLocalized: "任务") : String(appLocalized: "训练进程"), trailing: snap.tasks.isEmpty ? nil : "\(snap.tasks.count)")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(tasksExpanded ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(snap.tasks.isEmpty)

            if snap.tasks.isEmpty {
                Text("没有运行中的任务").font(.caption).foregroundStyle(.tertiary)
            } else if tasksExpanded {
                VStack(spacing: 5) {
                    ForEach(snap.tasks) { task in
                        TaskRow(task: task, isOpen: openTask == task.pid) {
                            openTask = openTask == task.pid ? nil : task.pid
                        }
                    }
                }
            }
        }
    }
}

struct TaskRow: View {
    var task: GPUTask
    var isOpen: Bool
    var toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .padding(7)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
            if isOpen {
                Divider().opacity(0.5).padding(.horizontal, 7)
                detail.padding(8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isOpen || hovering ? 0.07 : 0.04))
        )
        .onHover { hovering = $0 }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(TaskRow.shortCommand(task.command))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            HStack(spacing: 8) {
                Label(task.user, systemImage: "person")
                Label(Format.duration(task.elapsedSeconds.map(Double.init)), systemImage: "timer")
                if !task.gpuIndices.isEmpty {
                    Label("GPU " + task.gpuIndices.map(String.init).joined(separator: ","), systemImage: "square.stack.3d.up")
                }
                if let m = task.memoryMiB { Text(Format.mib(m)) }
                Spacer()
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("\(task.user) · \(Format.duration(task.elapsedSeconds.map(Double.init))) · GPU \(task.gpuIndices.map(String.init).joined(separator: ","))")
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.command)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.18)))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                if let cwd = task.cwd { field(String(appLocalized: "目录"), cwd, mono: true) }
                field("PID", "\(task.pid)", mono: true)
                field(String(appLocalized: "用户"), task.user)
                if let e = task.elapsedSeconds {
                    field(String(appLocalized: "开始于"), Date().addingTimeInterval(-Double(e)).formatted(date: .abbreviated, time: .shortened)
                        + String(appLocalized: " · 已运行 \(Format.duration(Double(e)))"), lines: 1)
                }
                if !task.gpuIndices.isEmpty {
                    field("GPU", task.gpuIndices.map(String.init).joined(separator: ", ")
                        + (task.memoryMiB.map { String(appLocalized: " · 显存 \(Format.mib($0))") } ?? ""))
                }
                if task.cpuPercent != nil || task.rssKB != nil {
                    field(String(appLocalized: "CPU / 内存"), "\(task.cpuPercent.map { "\(Int($0))%" } ?? "—") · \(Format.kb(task.rssKB))")
                }
            }
            .font(.system(size: 10))
            HStack(spacing: 4) {
                Spacer()
                Button { copy(task.command) } label: { Label("复制命令", systemImage: "doc.on.doc") }
                if let cwd = task.cwd {
                    Button { copy(cwd) } label: { Label("复制目录", systemImage: "folder") }
                }
                Button { copy("\(task.pid)") } label: { Label("复制 PID", systemImage: "number") }
            }
            .buttonStyle(IconButtonStyle())
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10))
        }
    }

    private func field(_ title: String, _ value: String, mono: Bool = false, lines: Int = 2) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
                .font(mono ? .system(size: 10, design: .monospaced) : .system(size: 10))
                .textSelection(.enabled)
                .lineLimit(lines)
                .truncationMode(.middle)
                .help(value)
        }
    }

    /// Drops the interpreter path, keeping e.g. `python train.py --lr 1e-4`.
    static func shortCommand(_ command: String) -> String {
        var parts = command.split(separator: " ").map(String.init)
        if let first = parts.first, first.contains("/") {
            parts[0] = String(first.split(separator: "/").last ?? "")
        }
        return parts.joined(separator: " ")
    }
}

func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
