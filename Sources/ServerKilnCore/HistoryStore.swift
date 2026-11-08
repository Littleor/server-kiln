import Foundation
import SQLite3

/// One aggregated point of a history series.
public struct HistoryPoint: Hashable, Sendable, Identifiable {
    public var time: Date
    /// GPU index, or `nil` for the server-wide aggregate.
    public var gpu: Int?
    /// GPU utilisation 0...100 (aggregate = mean over cards).
    public var utilization: Double?
    /// VRAM used fraction 0...1 (aggregate = Σused / Σtotal).
    public var memoryFraction: Double?
    public var memoryUsedMiB: Double?
    /// Host CPU usage 0...1 (aggregate rows only).
    public var cpu: Double?
    /// Host RAM used fraction 0...1 (aggregate rows only).
    public var ram: Double?

    public var id: String { "\(time.timeIntervalSince1970)-\(gpu ?? -1)" }

    public init(time: Date, gpu: Int?, utilization: Double?, memoryFraction: Double?, memoryUsedMiB: Double?,
                cpu: Double?, ram: Double?) {
        self.time = time
        self.gpu = gpu
        self.utilization = utilization
        self.memoryFraction = memoryFraction
        self.memoryUsedMiB = memoryUsedMiB
        self.cpu = cpu
        self.ram = ram
    }

    /// The aggregate row plus one row per GPU for a live snapshot.
    public static func points(from snap: ServerSnapshot, at time: Date) -> [HistoryPoint] {
        let gpus = snap.gpus
        let used = gpus.reduce(0) { $0 + $1.memoryUsedMiB }, total = gpus.reduce(0) { $0 + $1.memoryTotalMiB }
        var out = [HistoryPoint(time: time, gpu: nil,
                                utilization: gpus.isEmpty ? nil : gpus.reduce(0) { $0 + $1.utilization } / Double(gpus.count),
                                memoryFraction: total > 0 ? used / total : nil, memoryUsedMiB: gpus.isEmpty ? nil : used,
                                cpu: snap.system.cpuUsage, ram: snap.system.memFraction)]
        for g in gpus {
            out.append(HistoryPoint(time: time, gpu: g.index, utilization: g.utilization, memoryFraction: g.memoryFraction,
                                    memoryUsedMiB: g.memoryUsedMiB, cpu: nil, ram: nil))
        }
        return out
    }
}

/// The last few minutes of every poll, kept in memory for the 10-minute
/// history range (the SQLite store only keeps one sample per minute).
public struct RecentSamples: Sendable {
    public static let window: TimeInterval = 10 * 60
    private var samples: [UUID: [HistoryPoint]] = [:]
    private var last: [UUID: Date] = [:]

    public init() {}

    /// Keeps at most one sample every 5 s per server.
    public mutating func record(_ server: UUID, _ snap: ServerSnapshot, at now: Date = Date()) {
        if let t = last[server], now.timeIntervalSince(t) < 5 { return }
        last[server] = now
        var list = samples[server, default: []]
        list.append(contentsOf: HistoryPoint.points(from: snap, at: now))
        let cutoff = now.addingTimeInterval(-Self.window)
        if let first = list.firstIndex(where: { $0.time >= cutoff }), first > 0 { list.removeFirst(first) }
        samples[server] = list
    }

    public func points(_ server: UUID, perGPU: Bool, since: Date) -> [HistoryPoint] {
        (samples[server] ?? []).filter { $0.time >= since && ($0.gpu != nil) == perGPU }
    }

    public mutating func forget(_ server: UUID) {
        samples[server] = nil
        last[server] = nil
    }
}

/// Persists periodic samples of every server to SQLite so the history window
/// can draw utilisation / VRAM curves. Samples are throttled per server and
/// pruned beyond the retention window.
public actor HistoryStore {
    public static let aggregateGPU = -1

    private var db: OpaquePointer?
    private var lastWrite: [String: Date] = [:]
    private var lastPrune = Date.distantPast
    public var minimumInterval: TimeInterval
    public var retentionDays: Int

    public init(path: String, minimumInterval: TimeInterval = 60, retentionDays: Int = 30) {
        self.minimumInterval = minimumInterval
        self.retentionDays = retentionDays
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK { handle = nil }
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(handle, """
        CREATE TABLE IF NOT EXISTS samples (
            server TEXT NOT NULL,
            ts INTEGER NOT NULL,
            gpu INTEGER NOT NULL,
            util REAL, mem_used REAL, mem_total REAL, cpu REAL, ram REAL
        )
        """, nil, nil, nil)
        sqlite3_exec(handle, "CREATE INDEX IF NOT EXISTS samples_server_ts ON samples(server, ts)", nil, nil, nil)
        db = handle
    }

    deinit { sqlite3_close(db) }

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ServerKiln/history.sqlite").path
    }

    public func configure(retentionDays: Int) {
        self.retentionDays = retentionDays
        prune(now: Date())
    }

    /// Records a snapshot unless one was written for this server less than
    /// `minimumInterval` ago.
    public func record(server: UUID, snapshot: ServerSnapshot, at now: Date = Date()) {
        let key = server.uuidString
        if let last = lastWrite[key], now.timeIntervalSince(last) < minimumInterval { return }
        lastWrite[key] = now

        let ts = Int64(now.timeIntervalSince1970)
        exec("BEGIN")
        let gpus = snapshot.gpus
        let usedSum = gpus.reduce(0) { $0 + $1.memoryUsedMiB }
        let totalSum = gpus.reduce(0) { $0 + $1.memoryTotalMiB }
        let utilMean = gpus.isEmpty ? nil : gpus.reduce(0) { $0 + $1.utilization } / Double(gpus.count)
        insert(key, ts, Self.aggregateGPU, utilMean, gpus.isEmpty ? nil : usedSum, gpus.isEmpty ? nil : totalSum,
               snapshot.system.cpuUsage, snapshot.system.memFraction)
        for g in gpus {
            insert(key, ts, g.index, g.utilization, g.memoryUsedMiB, g.memoryTotalMiB, nil, nil)
        }
        exec("COMMIT")

        if now.timeIntervalSince(lastPrune) > 3600 { prune(now: now) }
    }

    /// Returns points averaged into `bucket`-second buckets.
    public func query(server: UUID, since: Date, bucket: TimeInterval, perGPU: Bool) -> [HistoryPoint] {
        let sql = """
        SELECT (ts / ?1) * ?1 AS b, gpu, AVG(util), AVG(mem_used), AVG(mem_total), AVG(cpu), AVG(ram)
        FROM samples
        WHERE server = ?2 AND ts >= ?3 AND \(perGPU ? "gpu >= 0" : "gpu = -1")
        GROUP BY b, gpu ORDER BY b, gpu
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(max(1, bucket)))
        sqlite3_bind_text(stmt, 2, server.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(since.timeIntervalSince1970))

        func col(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
        }
        var out: [HistoryPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let gpu = Int(sqlite3_column_int(stmt, 1))
            let used = col(3), total = col(4)
            out.append(HistoryPoint(
                // Centre the point in its bucket.
                time: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0)) + bucket / 2),
                gpu: gpu < 0 ? nil : gpu,
                utilization: col(2),
                memoryFraction: (used != nil && (total ?? 0) > 0) ? used! / total! : nil,
                memoryUsedMiB: used,
                cpu: col(5),
                ram: col(6)
            ))
        }
        return out
    }

    public func delete(server: UUID) {
        run("DELETE FROM samples WHERE server = ?1") { sqlite3_bind_text($0, 1, server.uuidString, -1, SQLITE_TRANSIENT) }
    }

    public func deleteAll() {
        exec("DELETE FROM samples")
        exec("VACUUM")
    }

    public func sizeInBytes() -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    public func prune(now: Date) {
        lastPrune = now
        let cutoff = Int64(now.timeIntervalSince1970) - Int64(retentionDays) * 86400
        run("DELETE FROM samples WHERE ts < ?1") { sqlite3_bind_int64($0, 1, cutoff) }
    }

    // MARK: - SQLite helpers

    private func insert(_ server: String, _ ts: Int64, _ gpu: Int, _ util: Double?, _ used: Double?, _ total: Double?, _ cpu: Double?, _ ram: Double?) {
        run("INSERT INTO samples (server, ts, gpu, util, mem_used, mem_total, cpu, ram) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)") { stmt in
            sqlite3_bind_text(stmt, 1, server, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, ts)
            sqlite3_bind_int(stmt, 3, Int32(gpu))
            for (i, v) in [util, used, total, cpu, ram].enumerated() {
                if let v { sqlite3_bind_double(stmt, Int32(i + 4), v) } else { sqlite3_bind_null(stmt, Int32(i + 4)) }
            }
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bind(stmt)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
