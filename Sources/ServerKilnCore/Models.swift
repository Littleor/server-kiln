import Foundation

/// A server the user wants to monitor. `target` is passed verbatim to `ssh`,
/// so an alias from `~/.ssh/config` reuses all of its settings.
public struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var target: String
    public var port: Int?
    public var enabled: Bool
    public var muted: Bool

    public init(id: UUID = UUID(), name: String, target: String, port: Int? = nil, enabled: Bool = true, muted: Bool = false) {
        self.id = id
        self.name = name
        self.target = target
        self.port = port
        self.enabled = enabled
        self.muted = muted
    }
}

public struct GPUStat: Codable, Hashable, Identifiable, Sendable {
    public var index: Int
    public var uuid: String
    public var name: String
    /// 0...100
    public var utilization: Double
    public var memoryUsedMiB: Double
    public var memoryTotalMiB: Double
    public var temperature: Double?
    public var powerDraw: Double?
    public var powerLimit: Double?

    public var id: Int { index }
    public var memoryFraction: Double {
        memoryTotalMiB > 0 ? min(1, memoryUsedMiB / memoryTotalMiB) : 0
    }

    public init(index: Int, uuid: String, name: String, utilization: Double, memoryUsedMiB: Double, memoryTotalMiB: Double,
                temperature: Double? = nil, powerDraw: Double? = nil, powerLimit: Double? = nil) {
        self.index = index
        self.uuid = uuid
        self.name = name
        self.utilization = utilization
        self.memoryUsedMiB = memoryUsedMiB
        self.memoryTotalMiB = memoryTotalMiB
        self.temperature = temperature
        self.powerDraw = powerDraw
        self.powerLimit = powerLimit
    }
}

/// A process running on the server. When `gpuIndices` is empty the process was
/// found by the CPU-side fallback heuristic (e.g. inside containers where
/// `nvidia-smi` cannot see host PIDs).
public struct GPUTask: Codable, Hashable, Identifiable, Sendable {
    public var pid: Int
    public var user: String
    public var elapsedSeconds: Int?
    public var command: String
    public var gpuIndices: [Int]
    public var memoryMiB: Double?
    public var cpuPercent: Double?
    /// Resident memory in KB.
    public var rssKB: Double?
    /// Working directory, when readable.
    public var cwd: String?

    public var id: Int { pid }

    public init(pid: Int, user: String, elapsedSeconds: Int?, command: String, gpuIndices: [Int] = [], memoryMiB: Double? = nil,
                cpuPercent: Double? = nil, rssKB: Double? = nil, cwd: String? = nil) {
        self.pid = pid
        self.user = user
        self.elapsedSeconds = elapsedSeconds
        self.command = command
        self.gpuIndices = gpuIndices
        self.memoryMiB = memoryMiB
        self.cpuPercent = cpuPercent
        self.rssKB = rssKB
        self.cwd = cwd
    }
}

public struct SystemStat: Codable, Hashable, Sendable {
    public var hostname: String = ""
    public var os: String = ""
    public var uptimeSeconds: Double?
    public var cpuCores: Int?
    /// 0...1
    public var cpuUsage: Double?
    public var load: [Double] = []
    public var memTotalKB: Double?
    public var memAvailableKB: Double?
    public var diskTotalKB: Double?
    public var diskUsedKB: Double?
    /// Cumulative network counters (bytes) and the uptime they were read at.
    public var netSampleUptime: Double?
    public var netRxBytes: Double?
    public var netTxBytes: Double?
    /// Throughput in bytes/second, derived from two consecutive samples by
    /// `SystemStat.withRates(previous:)`.
    public var netRxRate: Double?
    public var netTxRate: Double?

    public init() {}

    /// Fills `netRxRate` / `netTxRate` from the previous sample of the same host.
    public func withRates(previous: SystemStat?) -> SystemStat {
        var s = self
        guard let prev = previous, let t0 = prev.netSampleUptime, let t1 = netSampleUptime, t1 > t0,
              let rx0 = prev.netRxBytes, let rx1 = netRxBytes, let tx0 = prev.netTxBytes, let tx1 = netTxBytes,
              rx1 >= rx0, tx1 >= tx0
        else {
            // Keep the last known rate across a counter reset or the first sample.
            s.netRxRate = previous?.netRxRate
            s.netTxRate = previous?.netTxRate
            return s
        }
        s.netRxRate = (rx1 - rx0) / (t1 - t0)
        s.netTxRate = (tx1 - tx0) / (t1 - t0)
        return s
    }

    public var memFraction: Double? {
        guard let t = memTotalKB, let a = memAvailableKB, t > 0 else { return nil }
        return min(1, max(0, (t - a) / t))
    }

    public var diskFraction: Double? {
        guard let t = diskTotalKB, let u = diskUsedKB, t > 0 else { return nil }
        return min(1, u / t)
    }
}

public struct ServerSnapshot: Codable, Hashable, Sendable {
    public var system: SystemStat
    /// `false` when `nvidia-smi` is not installed (CPU-only server).
    public var hasNvidiaSMI: Bool
    public var gpus: [GPUStat]
    public var gpuError: String?
    public var tasks: [GPUTask]
    public var fetchedAt: Date
    /// Busiest processes by CPU and by memory (CPU-only servers and
    /// containers where nvidia-smi can't see PIDs); empty otherwise.
    public var processes: [GPUTask] = []

    public init(system: SystemStat, hasNvidiaSMI: Bool, gpus: [GPUStat], gpuError: String? = nil, tasks: [GPUTask],
                fetchedAt: Date = Date(), processes: [GPUTask] = []) {
        self.system = system
        self.hasNvidiaSMI = hasNvidiaSMI
        self.gpus = gpus
        self.gpuError = gpuError
        self.tasks = tasks
        self.fetchedAt = fetchedAt
        self.processes = processes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        system = try c.decode(SystemStat.self, forKey: .system)
        hasNvidiaSMI = try c.decode(Bool.self, forKey: .hasNvidiaSMI)
        gpus = try c.decode([GPUStat].self, forKey: .gpus)
        gpuError = try c.decodeIfPresent(String.self, forKey: .gpuError)
        tasks = try c.decode([GPUTask].self, forKey: .tasks)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        processes = try c.decodeIfPresent([GPUTask].self, forKey: .processes) ?? []
    }

    public var isGPUServer: Bool { hasNvidiaSMI && !gpus.isEmpty }
}

/// Decides whether a GPU counts as "in use". See PRD §4.
public struct BusyPolicy: Codable, Hashable, Sendable {
    public var utilizationThreshold: Double
    public var memoryThresholdMiB: Double

    public init(utilizationThreshold: Double = 10, memoryThresholdMiB: Double = 1024) {
        self.utilizationThreshold = utilizationThreshold
        self.memoryThresholdMiB = memoryThresholdMiB
    }

    public func isBusy(_ gpu: GPUStat) -> Bool {
        gpu.utilization >= utilizationThreshold || gpu.memoryUsedMiB >= memoryThresholdMiB
    }

    public func busyCount(_ snapshot: ServerSnapshot) -> Int {
        snapshot.gpus.filter(isBusy).count
    }
}
