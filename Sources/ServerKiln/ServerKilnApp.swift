import AppKit
import ServerKilnCore
import SwiftUI
import UserNotifications
import ServerKilnUI

@main
struct ServerKilnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var monitor = Monitor.shared
    @State private var settings = AppSettings.shared
    @State private var phone = PhoneSync.shared

    init() {
        // Writing to an ssh pipe that just died must surface as an error, not
        // kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Debug helper: `ServerKiln --probe <ssh-target>` prints one snapshot as JSON.
        let args = CommandLine.arguments
        #if DEBUG
        if args.contains("--check-updater-config") {
            do {
                try MacUpdater.validateConfiguration()
                print("PASS: updater starts and unattended installation is disabled")
                exit(0)
            } catch {
                print("FAIL: updater configuration:", error)
                exit(1)
            }
        }
        #endif
        if let i = args.firstIndex(of: "--probe"), i + 1 < args.count {
            Self.probe(args[i + 1])
        }
        // Build helper: `ServerKiln --write-iconset <dir>` renders the app icon.
        if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
            do { try BrandMark.writeIconset(to: args[i + 1]) } catch {
                fputs("error: \(error)\n", stderr)
                exit(1)
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--soak"), i + 3 < args.count {
            let secs = Double(args[i + 1]) ?? 120, interval = Double(args[i + 2]) ?? 1
            let targets = Array(args[(i + 3)...])
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await SessionSoak.run(seconds: secs, interval: interval, targets: targets)
                done.signal()
            }
            done.wait()
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let out = args[i + 1]
            // `-AppleLanguages (en)` etc. pick the language; the rest are ssh targets.
            var targets: [String] = []
            var rest = args[(i + 2)...].makeIterator()
            while let a = rest.next() {
                if a.hasPrefix("-Apple") || a == "--language" { _ = rest.next() } else { targets.append(a) }
            }
            Task { @MainActor in
                await SnapshotRenderer.run(outDir: out, targets: targets)
                exit(0)
            }
        }
    }

    private static func probe(_ target: String) -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let snap = try await SSHRunner.fetch(ServerConfig(name: target, target: target))
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                enc.dateEncodingStrategy = .iso8601
                print(String(decoding: try enc.encode(snap), as: UTF8.self))
            } catch {
                print("error: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(monitor)
                .environment(settings)
                .environment(phone)
                .modifier(AppLanguageModifier())
        } label: {
            MenuBarLabel()
                .environment(monitor)
                .environment(settings)
                .environment(phone)
                .modifier(AppLanguageModifier())
                .modifier(StressOpener())
        }
        .menuBarExtraStyle(.window)

        Window("ServerKiln 设置", id: "settings") {
            SettingsView()
                .environment(monitor)
                .environment(settings)
                .environment(phone)
                .modifier(AppLanguageModifier())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Window("ServerKiln 历史", id: "history") {
            HistoryView()
                .environment(monitor)
                .environment(settings)
                .environment(phone)
                .modifier(AppLanguageModifier())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 620)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        Notifier.requestAuthorization()
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
            if Notifier.isAvailable {
                UNUserNotificationCenter.current().delegate = NotificationClickHandler.shared
            }
            MacUpdater.shared.start()
        }
        Task { @MainActor in Monitor.shared.start() }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Monitor.shared.suspendSessions() }
        }
    }
}

/// Debug: `--stress-history` opens the history window at launch.
private struct StressOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard CommandLine.arguments.contains("--stress-history") else { return }
            try? await Task.sleep(for: .seconds(2))
            openWindow(id: "history")
        }
    }
}
