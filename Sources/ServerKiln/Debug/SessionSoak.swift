import Foundation
import ServerKilnCore

/// `ServerKiln --soak <seconds> <interval> <target…>`: polls each target through a
/// persistent session and reports latency / failures, to verify stability.
enum SessionSoak {
    static func run(seconds: Double, interval: Double, targets: [String]) async {
        await withTaskGroup(of: String.self) { group in
            for target in targets {
                group.addTask {
                    let session = SSHSession(server: ServerConfig(name: target, target: target))
                    var ok = 0, fail = 0, maxLat = 0.0, errors: [String] = []
                    let end = Date().addingTimeInterval(seconds)
                    while Date() < end {
                        let t = Date()
                        do {
                            _ = try await session.fetch()
                            ok += 1
                            maxLat = max(maxLat, Date().timeIntervalSince(t))
                        } catch {
                            fail += 1
                            errors.append(String(format: "%.0fs: %@", seconds - end.timeIntervalSinceNow, error.localizedDescription))
                            session.close()
                        }
                        let wait = interval - Date().timeIntervalSince(t)
                        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    }
                    session.close()
                    return "\(target): ok=\(ok) fail=\(fail) maxLatency=\(String(format: "%.2f", maxLat))s \(errors.prefix(5))"
                }
            }
            for await line in group { print(line) }
        }
    }
}
