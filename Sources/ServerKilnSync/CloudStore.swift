import CloudKit
import Foundation
import ServerKilnCore
#if os(macOS)
import Security
#endif

/// The user's private CloudKit database. Only the user's own iCloud account
/// can read it; no key material is ever written here (see `KeyVault`).
///
/// Layout (default zone, so no custom indexes are needed):
/// - `ServerList/mac-<id>`: JSON `SyncedPayload` in `payload`, one record per
///   Mac so several Macs never overwrite each other; phones merge them.
/// - `EventIdle` / `EventBusy` / `EventConnection`: one record per transition.
///   The phone subscribes per record type, so each notification kind can be
///   switched on and off without a queryable `kind` index.
public final class CloudStore: @unchecked Sendable {
    public static let containerID = "iCloud.cn.littleor.serverkiln"
    public static let shared = CloudStore()

    static let listType = "ServerList"

    public enum Channel: String, CaseIterable, Sendable {
        case idle = "EventIdle"
        case busy = "EventBusy"
        case connection = "EventConnection"

        public init(_ kind: ActivityEvent.Kind) {
            switch kind {
            case .idle: self = .idle
            case .busy: self = .busy
            case .offline, .online: self = .connection
            }
        }

        var subscriptionID: String { "serverkiln.\(rawValue)" }
    }

    /// CloudKit traps without the iCloud entitlement, which unsigned
    /// `swift run` builds of the Mac app don't have.
    public static let isAvailable: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains("CloudKit") ?? false
        #else
        return true
        #endif
    }()

    private lazy var database = CKContainer(identifier: Self.containerID).privateCloudDatabase

    public enum AccountState: Sendable {
        case available, noAccount, restricted, unavailable(String)

        public var message: String {
            switch self {
            case .available: return String(appLocalized: "iCloud 已连接")
            case .noAccount: return String(appLocalized: "未登录 iCloud")
            case .restricted: return String(appLocalized: "iCloud 受限")
            case let .unavailable(m): return m
            }
        }
    }

    public func accountState() async -> AccountState {
        guard Self.isAvailable else { return .unavailable(String(appLocalized: "此构建未启用 iCloud（需签名版本）")) }
        do {
            switch try await CKContainer(identifier: Self.containerID).accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            default: return .unavailable(String(appLocalized: "iCloud 暂不可用"))
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    // MARK: Errors

    /// Network blips, throttling and server hiccups: retry later, don't alarm.
    public static func isTransient(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return (error as NSError).domain == NSURLErrorDomain }
        switch ck.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .serverResponseLost, .notAuthenticated:
            return true
        default:
            return false
        }
    }

    /// Short Chinese text for errors that do need the user's attention.
    public static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .networkUnavailable, .networkFailure: return String(appLocalized: "网络不可用")
        case .notAuthenticated: return String(appLocalized: "未登录 iCloud")
        case .quotaExceeded: return String(appLocalized: "iCloud 空间已满")
        case .permissionFailure: return String(appLocalized: "没有 iCloud 权限")
        default: return String(appLocalized: "iCloud 错误 \(ck.code.rawValue)")
        }
    }

    // MARK: Servers

    /// Saves this Mac's list. `macID` is stable per Mac install. The
    /// `macs` record lists every Mac that ever published, so phones can fetch
    /// all lists by ID (no query, so no schema index needed).
    public func save(_ payload: SyncedPayload, macID: String) async throws {
        let id = CKRecord.ID(recordName: "mac-" + macID)
        let record = try await existing(id) ?? CKRecord(recordType: Self.listType, recordID: id)
        record["payload"] = try JSONEncoder().encode(payload) as CKRecordValue
        try await saveRecord(record, policy: .changedKeys)
        try await register(macID)
    }

    /// Adds this Mac to the `macs` index (idempotent, retried on races).
    private func register(_ macID: String) async throws {
        for _ in 0..<8 {
            let index = try await existing(Self.indexID) ?? CKRecord(recordType: Self.indexType, recordID: Self.indexID)
            var macs = (index["macs"] as? [String]) ?? []
            guard !macs.contains(macID) else { return }
            macs.append(macID)
            index["macs"] = macs as CKRecordValue
            do {
                try await saveRecord(index, policy: .ifServerRecordUnchanged)
                return
            } catch let e as CKError where e.code == .serverRecordChanged {
                continue // Another Mac registered at the same moment; retry.
            }
        }
        throw CKError(.serverRecordChanged)
    }

    private func saveRecord(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: policy)
        guard let result = results.saveResults[record.recordID] else { throw CKError(.internalError) }
        _ = try result.get()
    }

    // MARK: Status relay

    static let statusType = "MacStatus"

    /// Overwrites this Mac's status record (one per Mac, so no conflicts).
    public func saveStatus(_ status: RelayStatus, macID: String) async throws {
        let id = CKRecord.ID(recordName: "status-" + macID)
        let record = try await existing(id) ?? CKRecord(recordType: Self.statusType, recordID: id)
        record["payload"] = try JSONEncoder().encode(status) as CKRecordValue
        try await saveRecord(record, policy: .allKeys)
        try await register(macID)
    }

    public func fetchStatuses() async throws -> [RelayStatus] {
        guard let index = try await existing(Self.indexID), let macs = index["macs"] as? [String], !macs.isEmpty else { return [] }
        let results = try await database.records(for: macs.map { CKRecord.ID(recordName: "status-" + $0) }, desiredKeys: ["payload"])
        return try results.sorted { $0.key.recordName < $1.key.recordName }.compactMap { id, result in
            guard let record = try Self.fetchedRecord(result), let data = record["payload"] as? Data else { return nil }
            var status = try JSONDecoder().decode(RelayStatus.self, from: data)
            status.macID = String(id.recordName.dropFirst("status-".count))
            return status
        }
    }

    static let indexType = "MacIndex"
    static let indexID = CKRecord.ID(recordName: "macs")

    private func existing(_ id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let e as CKError where e.code == .unknownItem {
            return nil
        }
    }

    /// Every Mac's list, merged.
    public func fetch() async throws -> SyncedPayload {
        SyncedPayload.merge(try await fetchAll())
    }

    public func fetchAll() async throws -> [SyncedPayload] {
        guard let index = try await existing(Self.indexID), let macs = index["macs"] as? [String], !macs.isEmpty else { return [] }
        let results = try await database.records(for: macs.map { CKRecord.ID(recordName: "mac-" + $0) }, desiredKeys: ["payload"])
        return try results.sorted { $0.key.recordName < $1.key.recordName }.compactMap { id, result in
            guard let record = try Self.fetchedRecord(result), let data = record["payload"] as? Data else { return nil }
            var payload = try JSONDecoder().decode(SyncedPayload.self, from: data)
            payload.macID = String(id.recordName.dropFirst("mac-".count))
            return payload
        }
    }

    /// Missing records are normal for relay-only Macs; other failures must
    /// not turn a partial read into a successful, destructive list replacement.
    static func fetchedRecord(_ result: Result<CKRecord, Error>) throws -> CKRecord? {
        do { return try result.get() }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    // MARK: Events

    /// Saves one event under `recordName`; returns false when another device
    /// already posted the same transition (so it isn't pushed twice).
    @discardableResult
    public func post(_ event: ActivityEvent, recordName: String) async throws -> Bool {
        let id = CKRecord.ID(recordName: recordName)
        let record = CKRecord(recordType: Channel(event.kind).rawValue, recordID: id)
        record["serverID"] = event.serverID.uuidString as CKRecordValue
        record["kind"] = event.kind.rawValue as CKRecordValue
        record["title"] = event.title as CKRecordValue
        record["body"] = event.body as CKRecordValue
        record["date"] = event.date as CKRecordValue
        // `.ifServerRecordUnchanged` on a new record fails if it already exists.
        let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        if case let .failure(error)? = saved[id] {
            if let ck = error as? CKError, ck.code == .serverRecordChanged { return false }
            throw error
        }
        return true
    }

    public func delete(recordNames: [String]) async throws {
        guard !recordNames.isEmpty else { return }
        let results = try await database.modifyRecords(saving: [], deleting: recordNames.map { CKRecord.ID(recordName: $0) })
        for result in results.deleteResults.values { _ = try result.get() }
    }

    // MARK: Dedup across devices

    /// Atomically claims a transition. Exactly one device (Mac or phone)
    /// gets `true` per name; also refuses if the previous time bucket was
    /// claimed, so two Macs straddling a bucket boundary don't both push.
    public func claim(_ name: String, previous: String) async throws -> Bool {
        if try await exists([Self.seenPrefix + previous]) { return false }
        let id = CKRecord.ID(recordName: Self.seenPrefix + name)
        let record = CKRecord(recordType: "EventSeen", recordID: id)
        record["date"] = Date() as CKRecordValue
        let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        if case let .failure(error)? = saved[id] {
            if let ck = error as? CKError, ck.code == .serverRecordChanged { return false }
            throw error
        }
        return true
    }

    /// Whether a Mac already pushed this transition (current or previous bucket).
    public func wasPushed(_ name: String, previous: String) async throws -> Bool {
        try await exists([name, previous])
    }

    static let seenPrefix = "seen-"
    public static func seenPrefixed(_ name: String) -> String { seenPrefix + name }

    private func exists(_ names: [String]) async throws -> Bool {
        let results = try await database.records(for: names.map { CKRecord.ID(recordName: $0) }, desiredKeys: [])
        var found = false
        for result in results.values {
            if try Self.fetchedRecord(result) != nil { found = true }
        }
        return found
    }

    // MARK: Phone notification preferences

    /// The iPhone's per-server notification switches, shared through the
    /// user's private database so the Mac skips muted servers before posting.
    /// Stored as a `ServerList` record (existing production record type and
    /// fields) under its own name, so no schema deployment is needed.
    static let notificationPrefsID = CKRecord.ID(recordName: "phone-notification-prefs")

    public func fetchNotificationPrefs() async throws -> NotificationPrefs? {
        guard let record = try await existing(Self.notificationPrefsID),
              let data = record["payload"] as? Data else { return nil }
        return try JSONDecoder().decode(NotificationPrefs.self, from: data)
    }

    public func saveNotificationPrefs(_ prefs: NotificationPrefs) async throws {
        let record = try await existing(Self.notificationPrefsID)
            ?? CKRecord(recordType: Self.listType, recordID: Self.notificationPrefsID)
        record["payload"] = try JSONEncoder().encode(prefs) as CKRecordValue
        try await saveRecord(record, policy: .changedKeys)
    }

    // MARK: Subscriptions (phone)

    public func subscriptionIDs() async throws -> [String] {
        try await database.allSubscriptions().map(\.subscriptionID)
    }

    /// One unfiltered subscription per event type with a fixed ID: the shape
    /// that has been deployed to Production since 1.0.0. Per-server muting is
    /// applied by the Mac before it posts, never by a subscription predicate,
    /// because every new predicate shape needs its own Production deployment.
    static func eventSubscription(_ channel: Channel) -> CKQuerySubscription {
        let sub = CKQuerySubscription(recordType: channel.rawValue, predicate: NSPredicate(value: true),
                                      subscriptionID: channel.subscriptionID, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        // "%1$@" formats the record's own title/body fields.
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = ["body"]
        info.soundName = "default"
        info.desiredKeys = ["serverID", "kind"]
        info.shouldSendContentAvailable = true
        info.category = "serverkiln.event"
        sub.notificationInfo = info
        return sub
    }

    /// Subscriptions this app owns that should not exist for `enabled`:
    /// disabled channels plus anything left by earlier builds (filtered
    /// `.v2.` subscriptions and diagnostic probes).
    static func obsoleteSubscriptions(_ existing: Set<String>, enabled: Set<Channel>) -> [String] {
        let desired = Set(enabled.map(\.subscriptionID))
        return existing.filter { $0.hasPrefix("serverkiln.") && !desired.contains($0) }.sorted()
    }

    /// Makes the set of subscribed channels match `enabled`. Existing
    /// subscriptions are left untouched; missing ones are created first, then
    /// leftovers removed, so a failed save never deletes a working subscription.
    public func updateSubscriptions(enabled: Set<Channel>) async throws {
        let existing = Set(try await database.allSubscriptions().map(\.subscriptionID))
        let missing = Channel.allCases.filter { enabled.contains($0) && !existing.contains($0.subscriptionID) }
        if !missing.isEmpty {
            let results = try await database.modifySubscriptions(saving: missing.map(Self.eventSubscription), deleting: [])
            for result in results.saveResults.values { _ = try result.get() }
        }
        let obsolete = Self.obsoleteSubscriptions(existing, enabled: enabled)
        if !obsolete.isEmpty {
            let results = try await database.modifySubscriptions(saving: [], deleting: obsolete)
            for result in results.deleteResults.values { _ = try result.get() }
        }
    }
}
