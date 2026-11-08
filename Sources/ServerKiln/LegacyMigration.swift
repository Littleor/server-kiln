import Foundation
import ServerKilnCore

/// One-time carry-over from the app's former name (GPUBar): preferences lived
/// under `cn.littleor.gpubar`, history under `Application Support/GPUBar`.
/// Runs before settings load and before the history store opens.
enum LegacyMigration {
    private static let legacyDomain = "cn.littleor.gpubar"
    private static let legacyFolder = "GPUBar"

    static func run() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "servers") == nil,
           let old = defaults.persistentDomain(forName: legacyDomain) {
            for (key, value) in old { defaults.set(value, forKey: key) }
        }

        let fm = FileManager.default
        let newDB = URL(fileURLWithPath: HistoryStore.defaultPath)
        let newDir = newDB.deletingLastPathComponent()
        let oldDir = newDir.deletingLastPathComponent().appendingPathComponent(legacyFolder)
        if !fm.fileExists(atPath: newDir.path), fm.fileExists(atPath: oldDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
        }
    }
}
