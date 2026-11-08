import Foundation

/// A training job that ran on a server: what it was and when it ran.
public struct TaskRecord: Codable, Hashable, Identifiable, Sendable {
    public var command: String
    public var user: String
    public var cwd: String?
    public var gpuIndices: [Int]
    public var startedAt: Date
    /// nil while still running.
    public var endedAt: Date?

    public var id: String { "\(command)|\(startedAt.timeIntervalSince1970)" }
    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    public init(command: String, user: String, cwd: String?, gpuIndices: [Int], startedAt: Date, endedAt: Date? = nil) {
        self.command = command
        self.user = user
        self.cwd = cwd
        self.gpuIndices = gpuIndices
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Turns successive snapshots into "jobs": processes sharing a command line
/// (a torchrun launcher and its ranks, a DDP job's workers) form one job.
/// A job starts at its oldest process's start time and ends when none of its
/// processes are seen for `graceSeconds`, so a dropped poll or a brief
/// restart between epochs doesn't split it.
public struct TaskTracker: Codable, Sendable {
    public var running: [String: TaskRecord] = [:]
    /// Most recent first.
    public var finished: [TaskRecord] = []
    private var lastSeen: [String: Date] = [:]

    public static let graceSeconds: TimeInterval = 90
    public static let keep = 10

    public init() {}

    /// Groups processes into jobs keyed by a normalised command line.
    static func jobKey(_ task: GPUTask) -> String {
        // Worker spawns (`python -c from multiprocessing.spawn …`) belong to
        // whatever launched them; key them by working directory instead.
        if task.command.contains("multiprocessing.spawn") || task.command.contains("multiprocessing.forkserver") {
            return "spawn|" + (task.cwd ?? task.user)
        }
        // Drop per-rank flags so all ranks of a job share one key.
        let words = task.command.split(separator: " ").filter {
            !$0.hasPrefix("--local-rank") && !$0.hasPrefix("--local_rank") && !$0.hasPrefix("--rank")
        }
        return words.joined(separator: " ")
    }

    /// Feeds one snapshot's workload processes. Returns jobs that just ended.
    @discardableResult
    public mutating func observe(_ tasks: [GPUTask], at now: Date = Date()) -> [TaskRecord] {
        var groups: [String: [GPUTask]] = [:]
        for t in tasks { groups[Self.jobKey(t), default: []].append(t) }

        for (key, members) in groups {
            lastSeen[key] = now
            let oldest = members.max { ($0.elapsedSeconds ?? 0) < ($1.elapsedSeconds ?? 0) }!
            let started = now.addingTimeInterval(-Double(oldest.elapsedSeconds ?? 0))
            let gpus = Array(Set(members.flatMap(\.gpuIndices))).sorted()
            if var r = running[key] {
                r.gpuIndices = Array(Set(r.gpuIndices + gpus)).sorted()
                // Process start times only move earlier as more ranks appear.
                if started < r.startedAt { r.startedAt = started }
                running[key] = r
            } else {
                // The launcher (shortest command among same-key processes) is
                // the most readable line to show.
                let display = members.min { $0.command.count < $1.command.count }!
                running[key] = TaskRecord(command: display.command, user: display.user, cwd: display.cwd,
                                          gpuIndices: gpus, startedAt: started)
            }
        }

        var ended: [TaskRecord] = []
        for (key, record) in running where groups[key] == nil {
            guard let seen = lastSeen[key], now.timeIntervalSince(seen) >= Self.graceSeconds else { continue }
            var r = record
            r.endedAt = seen
            running[key] = nil
            lastSeen[key] = nil
            // Ignore blips: something that ran under a minute isn't a job.
            guard r.duration ?? 0 >= 60 else { continue }
            ended.append(r)
        }
        if !ended.isEmpty {
            finished = (ended.sorted { $0.endedAt! > $1.endedAt! } + finished).prefix(Self.keep).map { $0 }
        }
        return ended
    }

    /// The last finished job, for "上一条任务".
    public var last: TaskRecord? { finished.first }
}
