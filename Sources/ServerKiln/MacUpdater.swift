import AppKit
import Combine
import ServerKilnCore
import ServerKilnUI
import Sparkle
import SwiftUI

/// Sparkle owns verification, replacement, authorization and relaunch.
/// Automatic *installation* is forbidden in Info.plist; its standard update
/// alert always requires the user to choose Install Update.
@MainActor
final class MacUpdater: ObservableObject {
    static let shared = MacUpdater()
    nonisolated static let reminderID = "cn.littleor.serverkiln.update-available"
    @Published private(set) var canCheck = false
    @Published private(set) var checking = false
    /// A scheduled check found this version while the app was in the
    /// background. Sparkle holds the update; `checkForUpdates()` shows it.
    @Published private(set) var pendingVersion: String?
    @Published var automaticChecks = false {
        didSet {
            if started, controller.updater.automaticallyChecksForUpdates != automaticChecks {
                controller.updater.automaticallyChecksForUpdates = automaticChecks
            }
        }
    }

    private let reminder = GentleUpdateReminder()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: reminder)
    private var observations: [NSKeyValueObservation] = []
    private var started = false

    #if DEBUG
    /// Configuration-only probe: starts no download and exits before scheduling.
    static func validateConfiguration() throws {
        let reminder = GentleUpdateReminder()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: reminder)
        try controller.updater.start()
        guard !controller.updater.allowsAutomaticUpdates,
              !controller.updater.automaticallyDownloadsUpdates else {
            throw NSError(domain: "ServerKiln.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unattended installation must be disabled"])
        }
        guard reminder.supportsGentleScheduledUpdateReminders,
              !reminder.standardUserDriverShouldHandleShowingScheduledUpdate(SUAppcastItem.empty(), andInImmediateFocus: false) else {
            throw NSError(domain: "ServerKiln.Updates", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Background updates must use gentle reminders"])
        }
    }
    #endif

    func start() {
        guard !started, Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        started = true
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                Task { @MainActor in self?.canCheck = change.newValue ?? false }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                Task { @MainActor in self?.automaticChecks = change.newValue ?? false }
            }
        ]
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheck, !checking else { return }
        // Sparkle already holds the update found in the background; this
        // brings its confirmation alert into focus.
        if pendingVersion != nil {
            controller.checkForUpdates(nil)
            return
        }
        checking = true
        Task {
            defer { checking = false }
            // Old GitHub releases predate Sparkle. Avoid a misleading feed
            // error while the latest release has no appcast. Any API failure
            // (offline, rate limit) falls through to Sparkle, which reads the
            // feed itself and reports its own errors.
            guard let release = await Self.latestRelease(), !release.hasUpdateFeed else {
                controller.checkForUpdates(nil)
                return
            }
            let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            if release.isNewer(than: installed) {
                showMessage(String(appLocalized: "发现新版本"), String(appLocalized: "此版本尚未提供应用内更新，请从 GitHub Release 下载安装。"), offerRelease: true)
            } else {
                showMessage(String(appLocalized: "已是最新版本"), "ServerKiln \(installed)")
            }
        }
    }

    fileprivate func remind(_ version: String) {
        pendingVersion = version
        Notifier.post(title: String(appLocalized: "发现新版本"),
                      body: String(appLocalized: "ServerKiln \(version) 可以更新，点按查看。"),
                      identifier: Self.reminderID)
    }

    fileprivate func clearReminder() {
        pendingVersion = nil
        Notifier.remove(identifier: Self.reminderID)
    }

    private static func latestRelease() async -> MacGitHubRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Littleor/server-kiln/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ServerKiln", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(MacGitHubRelease.self, from: data)
    }

    private func showMessage(_ title: String, _ message: String, offerRelease: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: offerRelease ? String(appLocalized: "打开 GitHub Release") : String(appLocalized: "好"))
        if offerRelease { alert.addButton(withTitle: String(appLocalized: "取消")) }
        if alert.runModal() == .alertFirstButtonReturn, offerRelease {
            NSWorkspace.shared.open(URL(string: "https://github.com/Littleor/server-kiln/releases/latest")!)
        }
    }
}

/// A menu bar app has no window to come back to, so Sparkle's default alert
/// for a background check would open behind other apps. Unless Sparkle can
/// show it in immediate focus (just launched, or the user was idle), hold it
/// and remind through the panel and a notification instead.
/// https://sparkle-project.org/documentation/gentle-reminders/
private final class GentleUpdateReminder: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { MacUpdater.shared.remind(version) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { MacUpdater.shared.clearReminder() }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { MacUpdater.shared.clearReminder() }
    }
}

struct MacUpdateSettings: View {
    @ObservedObject private var updater = MacUpdater.shared

    var body: some View {
        SettingsGroup(title: String(appLocalized: "软件更新"),
                      info: String(appLocalized: "从 GitHub Releases 检查新版本。下载和安装前需要你确认，安装完成后自动重新打开应用。")) {
            SettingsToggle(title: String(appLocalized: "自动检查更新"), isOn: $updater.automaticChecks)
                .disabled(!updater.canCheck && !updater.automaticChecks)
            SettingsRow(title: String(appLocalized: "当前版本") + " " +
                        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")) {
                Button(buttonTitle) { updater.checkForUpdates() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!updater.canCheck || updater.checking)
            }
        }
    }

    private var buttonTitle: String {
        if updater.checking { return String(appLocalized: "检查中…") }
        if let version = updater.pendingVersion { return String(appLocalized: "查看新版本 \(version)…") }
        return String(appLocalized: "检查更新…")
    }
}
