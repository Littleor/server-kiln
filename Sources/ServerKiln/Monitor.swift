import Foundation
import ServerKilnCore
import ServerKilnUI
import ServerKilnSync
import Observation

struct ServerState: Equatable {
    var snapshot: ServerSnapshot?
    var error: String?
}

/// Central state: polls each enabled server in its own loop, derives
/// busy/idle status, records history and fires notifications on debounced
/// transitions. Polls faster while the menu bar panel is open.
@MainActor
@Observable
final class Monitor {
    static let shared = Monitor()

    /// Observed by the UI. Only written when content actually changes, so an
    /// unchanged poll costs no SwiftUI work.
    private(set) var states: [UUID: ServerState] = [:]
    /// Polling bookkeeping, deliberately not observed.
    @ObservationIgnored private var lastAttempt: [UUID: Date] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// Card order shown in the panel. Frozen while the panel is open so cards
    /// don't jump around under the cursor; recomputed whenever it opens.
    private(set) var displayOrder: [UUID] = []
    /// Server pre-selected when the history window opens.
    var historySelection: UUID?

    private(set) var panelVisible = false

    @ObservationIgnored let settings = AppSettings.shared
    @ObservationIgnored let history = HistoryStore(path: CommandLine.arguments.contains("--snapshot")
        ? NSTemporaryDirectory() + "serverkiln-snapshot-\(UUID().uuidString).sqlite"
        : HistoryStore.defaultPath)
    @ObservationIgnored private var loops: [UUID: Task<Void, Never>] = [:]
    /// One persistent ssh channel per server (see `SSHSession`).
    @ObservationIgnored private var sessions: [UUID: SSHSession] = [:]
    /// Consecutive failures. A server is only reported offline after
    /// `offlineThreshold` of them; until then the last data stays on screen.
    @ObservationIgnored private var failures: [UUID: Int] = [:]
    static let offlineThreshold = 3
    @ObservationIgnored private var tracker = TransitionTracker()
    /// Last successful poll per server (`snapshot.fetchedAt` is kept stable
    /// for unchanged data, so it is not a freshness signal).
    @ObservationIgnored private(set) var lastSuccess: [UUID: Date] = [:]
    /// Every poll of the last 10 minutes, for the history window's 10 分钟 range.
    @ObservationIgnored private(set) var recent = RecentSamples()
    /// Per-server job history ("上一条任务"), persisted across launches.
    /// Observed copy; only reassigned when a job starts or ends.
    private(set) var jobs: [UUID: TaskTracker] = Monitor.loadJobs()
    /// Working copy updated on every poll (last-seen times), not observed.
    @ObservationIgnored private lazy var trackers: [UUID: TaskTracker] = jobs

    private init() {}

    /// The interval currently in effect.
    var currentInterval: Double {
        panelVisible ? settings.fastRefreshInterval : settings.refreshInterval
    }

    func start() {
        Task { await history.configure(retentionDays: settings.historyRetentionDays) }
        PhoneSync.shared.updateCollectors(settings.servers)
        sync()
    }

    /// Starts loops for newly enabled servers and stops removed/disabled ones.
    func sync() {
        let enabled = Dictionary(uniqueKeysWithValues: settings.servers.filter(\.enabled).map { ($0.id, $0) })
        for (id, task) in loops where enabled[id] == nil {
            task.cancel()
            loops[id] = nil
            sessions.removeValue(forKey: id)?.close()
        }
        let known = Set(settings.servers.map(\.id))
        for id in states.keys where !known.contains(id) {
            states[id] = nil
            lastAttempt[id] = nil
            tracker.forget(id)
            recent.forget(id)
            jobs[id] = nil
            trackers[id] = nil
        }
        for id in enabled.keys where loops[id] == nil {
            loops[id] = Task { [weak self] in await self?.loop(id) }
        }
        if !panelVisible { recomputeOrder() }
    }

    /// Restarts every loop so a changed target / port applies immediately.
    func restart() {
        loops.values.forEach { $0.cancel() }
        loops = [:]
        sessions.values.forEach { $0.close() }
        sessions = [:]
        failures = [:]
        sync()
    }

    /// Closes all ssh channels (system sleep); they reopen on the next poll.
    func suspendSessions() {
        sessions.values.forEach { $0.close() }
        sessions = [:]
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        // The per-server loops notice the shorter interval within 250 ms and
        // refresh anything older than it, so no extra fetches are started here.
        if visible { recomputeOrder() }
    }

    private func loop(_ id: UUID) async {
        while !Task.isCancelled {
            guard let server = settings.servers.first(where: { $0.id == id }), server.enabled else { return }
            await refresh(server)
            // Always yield at least once: `refresh` returns immediately when a
            // fetch for this server is already running (e.g. manual refresh),
            // and looping without suspending would starve the main actor.
            repeat {
                try? await Task.sleep(for: .milliseconds(250))
            } while !Task.isCancelled && !isDue(id)
        }
    }

    /// Whether the server should be fetched again now.
    private func isDue(_ id: UUID) -> Bool {
        if inFlight.contains(id) { return false }
        guard let last = lastAttempt[id] else { return true }
        var interval = max(1, currentInterval)
        if let n = failures[id], n > 0 {
            if n < Self.offlineThreshold {
                // Transient failure: retry soon on a fresh connection.
                interval = min(interval, 3)
            } else {
                // Offline: back off 15 s, 30 s, 60 s … up to 5 min.
                let k = Double(min(n - Self.offlineThreshold, 5))
                interval = max(interval, min(300, 15 * pow(2, k)))
            }
        }
        return Date().timeIntervalSince(last) >= interval
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in settings.servers where server.enabled {
                group.addTask { await self.refresh(server) }
            }
        }
    }

    func refresh(_ server: ServerConfig) async {
        guard !inFlight.contains(server.id) else { return }
        inFlight.insert(server.id)
        defer {
            inFlight.remove(server.id)
            lastAttempt[server.id] = Date()
        }
        let result: Result<ServerSnapshot, Error>
        let session: SSHSession
        if let existing = sessions[server.id], existing.server == server {
            session = existing
        } else {
            sessions[server.id]?.close()
            session = SSHSession(server: server)
            sessions[server.id] = session
        }
        do {
            result = .success(try await session.fetch())
            failures[server.id] = nil
            lastSuccess[server.id] = Date()
        } catch {
            result = .failure(error)
            failures[server.id, default: 0] += 1
            session.close()
        }
        // The server may have been removed while we were waiting.
        guard settings.servers.contains(where: { $0.id == server.id }) else {
            states[server.id] = nil
            sessions.removeValue(forKey: server.id)?.close()
            return
        }
        var state = states[server.id] ?? ServerState()
        switch result {
        case var .success(snap):
            Task { await history.record(server: server.id, snapshot: snap) }
            recent.record(server.id, snap)
            recordJobs(server.id, snap)
            // Ignore the fetch timestamp when comparing, so identical data
            // doesn't trigger a redraw.
            snap.system = snap.system.withRates(previous: state.snapshot?.system)
            if let old = state.snapshot { snap.fetchedAt = old.fetchedAt }
            // Quantise noisy host metrics to whole percents for display.
            snap.system.cpuUsage = snap.system.cpuUsage.map { ($0 * 100).rounded() / 100 }
            snap.system.load = snap.system.load.map { ($0 * 10).rounded() / 10 }
            // Rates are only displayed with ~2 significant digits.
            snap.system.netRxRate = snap.system.netRxRate.map(Self.roughly)
            snap.system.netTxRate = snap.system.netTxRate.map(Self.roughly)
            state.snapshot = snap
            state.error = nil
        case let .failure(err):
            let n = failures[server.id] ?? 0
            // Before any data arrived there's nothing to keep showing.
            if n >= Self.offlineThreshold || (state.snapshot == nil && n >= 2) {
                state.error = err.localizedDescription
            }
        }
        if states[server.id] != state { states[server.id] = state }
        if !panelVisible || !displayOrder.contains(server.id) { recomputeOrder() }
        handleTransition(for: server)
        PhoneSync.shared.relay(states: states, sampled: lastSuccess, activity: activity, servers: settings.servers)
    }

    // MARK: - Job history

    private func recordJobs(_ id: UUID, _ snap: ServerSnapshot) {
        // GPU jobs from nvidia-smi; in containers the workload heuristic.
        var tracker = trackers[id] ?? TaskTracker()
        let before = (Set(tracker.running.keys), tracker.finished.first?.id)
        tracker.observe(snap.tasks.filter { snap.isGPUServer || SnapshotParser.isWorkload($0.command) })
        trackers[id] = tracker
        guard (Set(tracker.running.keys), tracker.finished.first?.id) != before else { return }
        jobs[id] = tracker
        saveJobs()
    }

    private static let jobsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ServerKiln/jobs.json")
    }()

    private static func loadJobs() -> [UUID: TaskTracker] {
        guard !CommandLine.arguments.contains("--snapshot"), let data = try? Data(contentsOf: jobsURL) else { return [:] }
        return (try? JSONDecoder().decode([UUID: TaskTracker].self, from: data)) ?? [:]
    }

    private func saveJobs() {
        guard !CommandLine.arguments.contains("--snapshot"), let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: Self.jobsURL, options: .atomic)
    }

    /// Rounds to 2 significant digits so tiny rate jitter doesn't redraw.
    private static func roughly(_ v: Double) -> Double {
        guard v > 0 else { return 0 }
        let m = pow(10, floor(log10(v)) - 1)
        return (v / m).rounded() * m
    }

    /// Used by the `--snapshot` preview renderer.
    /// Used by the `--snapshot` preview renderer.
    func injectJobs(_ id: UUID, finished: [TaskRecord]) {
        var t = TaskTracker()
        t.finished = finished
        jobs[id] = t
    }

    func inject(_ id: UUID, _ state: ServerState) {
        states[id] = state
        recomputeOrder()
    }

    // MARK: - Derived state

    func activity(_ server: ServerConfig) -> ServerActivity? {
        guard let state = states[server.id] else { return nil }
        if state.error != nil { return .offline }
        guard let snap = state.snapshot else { return nil }
        if !snap.isGPUServer { return .cpuOnly }
        return settings.busyPolicy.busyCount(snap) > 0 ? .busy : .idle
    }

    func connection(_ server: ServerConfig) -> ConnectionStatus {
        guard let state = states[server.id] else { return .connecting }
        if state.error != nil { return .offline }
        return state.snapshot == nil ? .connecting : .online
    }

    var enabledServers: [ServerConfig] { settings.servers.filter(\.enabled) }

    /// Enabled servers in `displayOrder`; servers not yet ordered go last.
    var sortedServers: [ServerConfig] {
        let rank = Dictionary(uniqueKeysWithValues: displayOrder.enumerated().map { ($1, $0) })
        return enabledServers.enumerated()
            .sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// busy (most loaded first) → idle → cpu-only → connecting → offline,
    /// keeping the user's order within a group.
    private func recomputeOrder() {
        func rank(_ a: ServerActivity?) -> Int {
            switch a {
            case .busy: return 0
            case .idle: return 1
            case .cpuOnly: return 2
            case .none: return 3
            case .offline: return 4
            }
        }
        displayOrder = enabledServers.enumerated()
            .sorted { (rank(activity($0.element)), $0.offset) < (rank(activity($1.element)), $1.offset) }
            .map(\.element.id)
    }

    struct Summary {
        var busyServers = 0
        var gpuServers = 0
        var busyGPUs = 0
        var totalGPUs = 0
        var offline = 0
        var cpuOnly = 0
        var online = 0
        var total = 0
        var vramUsedMiB: Double = 0
        var vramTotalMiB: Double = 0
    }

    var summary: Summary {
        var s = Summary()
        let policy = settings.busyPolicy
        for server in enabledServers {
            s.total += 1
            if connection(server) == .online { s.online += 1 }
            switch activity(server) {
            case .offline: s.offline += 1
            case .cpuOnly: s.cpuOnly += 1
            case .busy, .idle:
                guard let snap = states[server.id]?.snapshot else { continue }
                s.gpuServers += 1
                s.totalGPUs += snap.gpus.count
                s.vramUsedMiB += snap.gpus.reduce(0) { $0 + $1.memoryUsedMiB }
                s.vramTotalMiB += snap.gpus.reduce(0) { $0 + $1.memoryTotalMiB }
                let busy = policy.busyCount(snap)
                s.busyGPUs += busy
                if busy > 0 { s.busyServers += 1 }
            case .none: break
            }
        }
        return s
    }

    // MARK: - Notifications

    private func handleTransition(for server: ServerConfig) {
        guard let activity = activity(server) else { return }
        tracker.requiredStreak = max(1, settings.debounceCount)
        guard let t = tracker.observe(server.id, activity), !server.muted else { return }
        let snap = states[server.id]?.snapshot
        let total = snap?.gpus.count ?? 0
        let busy = snap.map { settings.busyPolicy.busyCount($0) } ?? 0

        // The phone gets every kind and filters with its own switches.
        let event: (ActivityEvent.Kind, String, String, Bool)?
        switch (t.from, t.to) {
        case (.busy, .idle):
            event = (.idle, String(appLocalized: "\(server.name) 已空闲"), String(appLocalized: "\(total) 张卡全部可用"), settings.notifyOnIdle)
        case (.idle, .busy):
            event = (.busy, String(appLocalized: "\(server.name) 开始训练"), String(appLocalized: "\(busy)/\(total) 张卡正在使用"), settings.notifyOnBusy)
        case (_, .offline):
            event = (.offline, String(appLocalized: "\(server.name) 离线"), states[server.id]?.error ?? String(appLocalized: "无法连接"), settings.notifyOnOffline)
        case (.offline, _):
            event = (.online, String(appLocalized: "\(server.name) 已恢复连接"), String(appLocalized: "连接已恢复"), settings.notifyOnOffline)
        default:
            event = nil
        }
        guard let (kind, title, body, local) = event else { return }
        if local { Notifier.post(title: title, body: body, id: server.id) }
        PhoneSync.shared.post(ActivityEvent(serverID: server.id, kind: kind, title: title, body: body), server: server)
        // Push right away so the phone's relay reflects the change too.
        PhoneSync.shared.relayNow()
    }
}
