import Foundation
import ServerKilnCore
import Observation

enum MenuBarStyle: String, CaseIterable, Identifiable, Codable {
    case servers, serversAndGPUs, busyOverTotal, gpus, vram

    var id: String { rawValue }
    var title: String {
        switch self {
        case .servers: return String(appLocalized: "忙碌服务器数")
        case .serversAndGPUs: return String(appLocalized: "服务器 · GPU 卡数")
        case .busyOverTotal: return String(appLocalized: "忙碌 / 总数")
        case .gpus: return String(appLocalized: "忙碌卡 / 总卡")
        case .vram: return String(appLocalized: "已用显存 / 总显存")
        }
    }
}

/// User preferences, persisted to `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings(defaults: store)

    var servers: [ServerConfig] {
        didSet {
            save(servers, "servers")
            PhoneSync.shared.serversChanged(servers)
        }
    }
    var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    var utilizationThreshold: Double {
        didSet {
            defaults.set(utilizationThreshold, forKey: "utilizationThreshold")
            PhoneSync.shared.republish()
        }
    }
    var memoryThresholdMiB: Double {
        didSet {
            defaults.set(memoryThresholdMiB, forKey: "memoryThresholdMiB")
            PhoneSync.shared.republish()
        }
    }
    var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    var menuBarSecondStyle: MenuBarStyle { didSet { defaults.set(menuBarSecondStyle.rawValue, forKey: "menuBarSecondStyle") } }
    var menuBarDualRow: Bool { didSet { defaults.set(menuBarDualRow, forKey: "menuBarDualRow") } }
    var notifyOnIdle: Bool { didSet { defaults.set(notifyOnIdle, forKey: "notifyOnIdle") } }
    var notifyOnBusy: Bool { didSet { defaults.set(notifyOnBusy, forKey: "notifyOnBusy") } }
    var notifyOnOffline: Bool { didSet { defaults.set(notifyOnOffline, forKey: "notifyOnOffline") } }
    var debounceCount: Int { didSet { defaults.set(debounceCount, forKey: "debounceCount") } }
    /// Poll interval while the menu bar panel is open.
    var fastRefreshInterval: Double { didSet { defaults.set(fastRefreshInterval, forKey: "fastRefreshInterval") } }
    var historyRetentionDays: Int { didSet { defaults.set(historyRetentionDays, forKey: "historyRetentionDays") } }
    /// The three-step welcome in the panel; shown until finished or skipped.
    var finishedGuide: Bool { didSet { defaults.set(finishedGuide, forKey: "finishedGuide") } }
    /// Page the settings window should switch to when it next appears.
    @ObservationIgnored var requestedSettingsPage: SettingsPage?

    @ObservationIgnored private let defaults: UserDefaults

    /// `--snapshot` renders previews with a throwaway store so real settings stay untouched.
    static let store: UserDefaults = {
        guard CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--subscription-schema-check") else {
            LegacyMigration.run()
            return .standard
        }
        let d = UserDefaults(suiteName: "cn.littleor.serverkiln.snapshot")!
        d.removePersistentDomain(forName: "cn.littleor.serverkiln.snapshot")
        return d
    }()

    var busyPolicy: BusyPolicy {
        BusyPolicy(utilizationThreshold: utilizationThreshold, memoryThresholdMiB: memoryThresholdMiB)
    }

    init(defaults d: UserDefaults) {
        defaults = d
        d.register(defaults: [
            "refreshInterval": 30.0,
            "utilizationThreshold": 10.0,
            "memoryThresholdMiB": 1024.0,
            "menuBarStyle": MenuBarStyle.servers.rawValue,
            "menuBarSecondStyle": MenuBarStyle.vram.rawValue,
            "menuBarDualRow": false,
            "notifyOnIdle": true,
            "notifyOnBusy": true,
            "notifyOnOffline": false,
            "debounceCount": 2,
            "fastRefreshInterval": 3.0,
            "historyRetentionDays": 30,
        ])
        servers = (d.data(forKey: "servers").flatMap { try? JSONDecoder().decode([ServerConfig].self, from: $0) }) ?? []
        refreshInterval = d.double(forKey: "refreshInterval")
        utilizationThreshold = d.double(forKey: "utilizationThreshold")
        memoryThresholdMiB = d.double(forKey: "memoryThresholdMiB")
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .servers
        menuBarSecondStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarSecondStyle") ?? "") ?? .vram
        menuBarDualRow = d.bool(forKey: "menuBarDualRow")
        notifyOnIdle = d.bool(forKey: "notifyOnIdle")
        notifyOnBusy = d.bool(forKey: "notifyOnBusy")
        notifyOnOffline = d.bool(forKey: "notifyOnOffline")
        debounceCount = d.integer(forKey: "debounceCount")
        fastRefreshInterval = d.double(forKey: "fastRefreshInterval")
        historyRetentionDays = d.integer(forKey: "historyRetentionDays")
        // Existing users already set things up; only new installs see the guide.
        finishedGuide = d.bool(forKey: "finishedGuide") || d.object(forKey: "servers") != nil
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    func addServers(_ new: [ServerConfig]) {
        let existing = Set(servers.map(\.target))
        servers.append(contentsOf: new.filter { !existing.contains($0.target) })
    }
}
