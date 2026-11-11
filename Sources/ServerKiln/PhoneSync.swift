import Foundation
import Observation
import ServerKilnCore
import ServerKilnSSH
import ServerKilnSync

/// Mac side of PRD §5.9: deploys the iPhone's dedicated keys, publishes the
/// server list to the private CloudKit database and pushes transitions.
@MainActor
@Observable
final class PhoneSync {
    static let shared = PhoneSync(defaults: AppSettings.store)

    /// Servers deployed for the phone, keyed by server ID. Mirrors CloudKit.
    private(set) var synced: [UUID: SyncedServer] { didSet { save(synced, "phoneSynced") } }
    var pushEnabled: Bool { didSet { defaults.set(pushEnabled, forKey: "phonePushEnabled"); retryPendingPushes() } }
    /// Progress / result text per server while (or after) deploying.
    private(set) var status: [UUID: String] = [:]
    private(set) var busy: Set<UUID> = []
    private(set) var account: CloudStore.AccountState?
    /// Latest unresolved problem, cleared as soon as that area succeeds again.
    var lastError: String? { errors.sorted { $0.key.rawValue < $1.key.rawValue }.first?.value }
    private var errors: [ErrorArea: String] = [:]
    enum ErrorArea: Int { case list, relay, push }
    private func report(_ area: ErrorArea, _ text: String) { errors[area] = text }
    private func clearError(_ area: ErrorArea) { if errors[area] != nil { errors[area] = nil } }
    @ObservationIgnored private var relayFailures = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cloud = CloudStore.shared
    /// Posted event record names and when, for the 7-day expiry.
    @ObservationIgnored private var postedEvents: [String: Date] {
        didSet { save(postedEvents, "phonePostedEvents") }
    }
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    private struct PendingPush: Codable {
        var event: ActivityEvent
        var previous: String
    }
    @ObservationIgnored private var pendingPushes: [String: PendingPush] = [:] {
        didSet { save(pendingPushes, "phonePendingPushes") }
    }
    @ObservationIgnored private var pushing: Set<String> = []

    static let eventRetention: TimeInterval = 7 * 86400

    /// Identifies this Mac's list in iCloud; stable across launches.
    @ObservationIgnored private lazy var macID: String = {
        if let id = defaults.string(forKey: "phoneMacID") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "phoneMacID")
        return id
    }()

    init(defaults d: UserDefaults) {
        defaults = d
        d.register(defaults: ["phonePushEnabled": true, "phoneRelayEnabled": true])
        synced = (d.data(forKey: "phoneSynced").flatMap { try? JSONDecoder().decode([UUID: SyncedServer].self, from: $0) }) ?? [:]
        postedEvents = (d.data(forKey: "phonePostedEvents").flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) }) ?? [:]
        pendingPushes = d.data(forKey: "phonePendingPushes").flatMap {
            try? JSONDecoder().decode([String: PendingPush].self, from: $0)
        } ?? [:]
        pushEnabled = d.bool(forKey: "phonePushEnabled")
        relayEnabled = d.bool(forKey: "phoneRelayEnabled")
        relayExcluded = (d.data(forKey: "phoneRelayExcluded").flatMap { try? JSONDecoder().decode(Set<UUID>.self, from: $0) }) ?? []
        if !CommandLine.arguments.contains("--subscription-schema-check") {
            Task { retryPendingPushes() }
        }
    }

    var isAvailable: Bool { CloudStore.isAvailable }

    func refreshAccount() async {
        account = await cloud.accountState()
    }

    /// Pushes the current collector to every deployed server whose copy is
    /// older (after an app update), so the phone gets the same data as the Mac.
    func updateCollectors(_ servers: [ServerConfig]) {
        let version = AuthorizedKeys.collectorVersion
        for server in servers where synced[server.id] != nil && collectorVersions[server.id.uuidString] != version {
            Task {
                guard let out = try? await SSHRunner.run(SSHRunner.arguments(for: server, connectTimeout: 10),
                                                         stdin: AuthorizedKeys.updateCollectorScript(), timeout: 30),
                      out.contains("@@DONE") else { return }
                markCollectorCurrent(server.id)
            }
        }
    }

    private var collectorVersions: [String: String] {
        (defaults.dictionary(forKey: "phoneCollectorVersions") as? [String: String]) ?? [:]
    }

    private func markCollectorCurrent(_ id: UUID) {
        var v = collectorVersions
        v[id.uuidString] = AuthorizedKeys.collectorVersion
        defaults.set(v, forKey: "phoneCollectorVersions")
    }

    // MARK: Deploy / revoke

    func deploy(_ server: ServerConfig, terminal: Bool) {
        guard !busy.contains(server.id) else { return }
        busy.insert(server.id)
        status[server.id] = String(appLocalized: "准备中…")
        let order = AppSettings.shared.servers.firstIndex { $0.id == server.id } ?? 0
        Task {
            defer { busy.remove(server.id) }
            do {
                let record = try await KeyDeployer.deploy(server, includeTerminal: terminal, order: order) { text in
                    Task { @MainActor in self.status[server.id] = text }
                }
                synced[server.id] = record
                markCollectorCurrent(server.id)
                status[server.id] = String(appLocalized: "✓ 已启用")
                schedulePublish(immediately: true)
            } catch {
                // A failed rotation rolls back the old lines and keys too, so
                // the phone's record would point at nothing.
                if synced.removeValue(forKey: server.id) != nil { schedulePublish(immediately: true) }
                status[server.id] = "✗ \(error.localizedDescription)"
            }
        }
    }

    func revoke(_ server: ServerConfig) {
        guard !busy.contains(server.id) else { return }
        busy.insert(server.id)
        status[server.id] = String(appLocalized: "撤销中…")
        // Drop it from the phone first, synchronously, so a deletion that
        // follows doesn't revoke a second time.
        synced[server.id] = nil
        schedulePublish(immediately: true)
        Task {
            defer { busy.remove(server.id) }
            if let error = await KeyDeployer.revoke(server) {
                status[server.id] = String(appLocalized: "⚠︎ 本地密钥已删除，服务器未连上：\(error.localizedDescription)。连上后请再撤销一次")
            } else {
                status[server.id] = String(appLocalized: "已撤销")
            }
        }
    }

    /// Keeps names, order and mute state in step with the Mac's list and
    /// revokes servers that were deleted.
    func serversChanged(_ servers: [ServerConfig]) {
        var changed = false
        for (id, record) in synced {
            guard let i = servers.firstIndex(where: { $0.id == id }) else {
                // Deleted on the Mac: cut the phone off too.
                synced[id] = nil
                changed = true
                let ep = record.endpoint
                Task { _ = await KeyDeployer.revoke(ServerConfig(id: id, name: record.name, target: "\(ep.user)@\(ep.host)", port: ep.port)) }
                continue
            }
            let s = servers[i]
            if record.name != s.name || record.order != i || record.muted != s.muted {
                var r = record
                r.name = s.name
                r.order = i
                r.muted = s.muted
                synced[id] = r
                changed = true
            }
        }
        if changed { schedulePublish(immediately: false) }
    }

    private func schedulePublish(immediately: Bool) {
        guard isAvailable else { return }
        publishTask?.cancel()
        let payload = SyncedPayload(servers: synced.values.sorted { $0.order < $1.order }, policy: AppSettings.shared.busyPolicy,
                                    macName: Host.current().localizedName)
        let macID = macID
        publishTask = Task {
            if !immediately { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            // Transient failures (network blip, wake from sleep) retry quietly.
            for attempt in 0..<4 {
                do {
                    try await cloud.save(payload, macID: macID)
                    clearError(.list)
                    return
                } catch where CloudStore.isTransient(error) && attempt < 3 {
                    try? await Task.sleep(for: .seconds(5 * (attempt + 1)))
                    if Task.isCancelled { return }
                } catch {
                    report(.list, String(appLocalized: "同步失败：\(CloudStore.describe(error))"))
                    return
                }
            }
        }
    }

    func republish() { schedulePublish(immediately: true) }

    // MARK: Status relay (PRD F9.9)

    /// Relays every enabled server (deployed or not) so the phone can show
    /// machines only this Mac can reach. Throttled: at most once per
    /// `relayInterval`, earlier only when someone's busy/idle/offline state
    /// changed, and never while nothing changed at all.
    var relayEnabled: Bool { didSet { defaults.set(relayEnabled, forKey: "phoneRelayEnabled") } }
    /// Servers kept out of the relay (per server, Settings → iPhone).
    var relayExcluded: Set<UUID> {
        didSet {
            save(relayExcluded, "phoneRelayExcluded")
            relayNow()
        }
    }
    @ObservationIgnored private var lastRelay: Date = .distantPast
    @ObservationIgnored private var lastRelaySignature: [String: String] = [:]
    @ObservationIgnored private var relayTask: Task<Void, Never>?
    static let relayInterval: TimeInterval = 60

    /// A non-deployed server as the phone sees it: no keys, no host pin, and
    /// `ssh -G`-resolved endpoint so it matches a deployment from another Mac.
    func relayIdentity(_ config: ServerConfig, order: Int) -> SyncedServer {
        let r = resolved[config.target]
        return SyncedServer(id: config.id, name: config.name,
                            endpoint: SSHEndpoint(host: r?.host ?? config.target, port: r?.port ?? config.port ?? 22,
                                                  user: r?.user ?? "", hostKeys: []),
                            roles: [], order: order, muted: config.muted)
    }

    /// `ssh -G` results, filled in the background (it spawns a process).
    @ObservationIgnored private var resolved: [String: KeyDeployer.Resolved] = [:]
    @ObservationIgnored private var resolving: Set<String> = []

    private func resolveIfNeeded(_ servers: [ServerConfig]) {
        for s in servers where resolved[s.target] == nil && !resolving.contains(s.target) {
            resolving.insert(s.target)
            Task {
                if let r = try? await KeyDeployer.resolve(s) { resolved[s.target] = r }
                resolving.remove(s.target)
            }
        }
    }

    /// Lets the next `relay` call publish immediately.
    func relayNow() { lastRelay = .distantPast; lastRelaySignature = [:] }

    func relay(states: [UUID: ServerState], sampled: [UUID: Date], activity: (ServerConfig) -> ServerActivity?,
               servers: [ServerConfig]) {
        retryPendingPushes()
        guard relayEnabled, isAvailable, relayTask == nil else { return }
        resolveIfNeeded(servers)
        var signature: [String: String] = [:]
        var entries: [RelayStatus.Server] = []
        let now = Date()
        for (i, server) in servers.enumerated() where server.enabled && !relayExcluded.contains(server.id) {
            guard let state = states[server.id], state.snapshot != nil || state.error != nil else { continue }
            let record = synced[server.id] ?? relayIdentity(server, order: i)
            var r = record
            r.order = i
            r.name = server.name
            r.muted = server.muted
            entries.append(.init(server: r, snapshot: state.snapshot, error: state.error, sampledAt: state.error == nil ? (sampled[server.id] ?? now) : now, finishedTasks: Monitor.shared.jobs[server.id]?.finished))
            signature[server.id.uuidString] = activity(server).map(\.rawValue) ?? "?"
        }
        let stateChanged = signature != lastRelaySignature
        guard stateChanged ? now.timeIntervalSince(lastRelay) > 5 : now.timeIntervalSince(lastRelay) >= Self.relayInterval else { return }
        lastRelay = now
        lastRelaySignature = signature
        let status = RelayStatus(macName: Host.current().localizedName ?? "Mac", updatedAt: now, servers: entries)
        let macID = macID
        relayTask = Task {
            defer { relayTask = nil }
            do {
                try await cloud.saveStatus(status, macID: macID)
                relayFailures = 0
                clearError(.relay)
            } catch {
                // The next poll retries; a single blip is not worth a warning.
                relayFailures += 1
                lastRelay = .distantPast
                if !CloudStore.isTransient(error) || relayFailures >= 5 {
                    report(.relay, String(appLocalized: "状态中转失败：\(CloudStore.describe(error))"))
                }
            }
        }
    }

    // MARK: Events

    /// Posts a transition to every iPhone, unless another Mac (or a phone's
    /// own background check) already claimed the same transition.
    /// Every monitored server notifies, including machines only this Mac can
    /// reach (they show up on the phone through the status relay).
    func post(_ event: ActivityEvent, server config: ServerConfig) {
        guard pushEnabled, isAvailable else { return }
        // Same identity the relay uses, so phones dedupe consistently.
        let server = synced[event.serverID] ?? relayIdentity(config, order: 0)
        // Several Macs watching the same machine share this name, so only
        // the first one's save creates a push.
        let name = ActivityEvent.dedupName(endpointKey: server.endpointKey, kind: event.kind, date: event.date)
        let previous = ActivityEvent.dedupName(endpointKey: server.endpointKey, kind: event.kind, date: event.date, previous: true)
        pendingPushes[name] = PendingPush(event: event, previous: previous)
        retryPendingPushes()
    }

    /// Durable outbox: network failures retry without losing the transition.
    /// The event record itself is the atomic claim, so a failed post cannot
    /// leave a separate claim that prevents its own retry.
    private func retryPendingPushes() {
        guard pushEnabled, isAvailable else { return }
        let cutoff = Date().addingTimeInterval(-Self.eventRetention)
        for (name, pending) in pendingPushes {
            if pending.event.date < cutoff { pendingPushes[name] = nil; continue }
            guard !pushing.contains(name) else { continue }
            pushing.insert(name)
            Task {
                defer { pushing.remove(name) }
                for attempt in 0..<5 {
                    guard pushEnabled, !Task.isCancelled else { return }
                    do {
                        if try await !cloud.wasPushed(name, previous: pending.previous) {
                            try await cloud.post(pending.event, recordName: name)
                        }
                        pendingPushes[name] = nil
                        postedEvents[name] = pending.event.date
                        if pendingPushes.isEmpty { clearError(.push) }
                        // Cleanup is independent of delivery; failure here is
                        // retried after the next successful event.
                        let expired = postedEvents.filter { $0.value < cutoff }.map(\.key)
                        if !expired.isEmpty {
                            do {
                                try await cloud.delete(recordNames: expired)
                                for key in expired { postedEvents[key] = nil }
                            } catch { /* Delivery already succeeded. */ }
                        }
                        return
                    } catch {
                        if !CloudStore.isTransient(error) {
                            report(.push, String(appLocalized: "推送失败：\(CloudStore.describe(error))"))
                            return
                        }
                        report(.push, String(appLocalized: "推送等待网络恢复，将自动重试"))
                        do { try await Task.sleep(for: .seconds(min(300, 15 * (1 << attempt)))) }
                        catch { return }
                    }
                }
            }
        }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
