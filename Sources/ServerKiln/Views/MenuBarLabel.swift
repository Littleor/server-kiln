import ServerKilnCore
import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let summary = monitor.summary
        let styles = settings.menuBarDualRow ? [settings.menuBarStyle, settings.menuBarSecondStyle] : [settings.menuBarStyle]
        let values = settings.servers.isEmpty ? [] : styles.map { $0.text(summary) }
        let description = ([summary.offline > 0 ? String(appLocalized: "ServerKiln，\(summary.offline) 台服务器离线") : "ServerKiln"]
            + (settings.servers.isEmpty ? [] : styles.map { "\($0.title)：\($0.text(summary))" })).joined(separator: "；")
        Image(nsImage: MenuBarArtwork.image(values: values, offline: summary.offline > 0))
            .accessibilityLabel(description)
            .help(description)
    }
}

extension MenuBarStyle {
    func text(_ summary: Monitor.Summary) -> String {
        switch self {
        case .servers: return "\(summary.busyServers)"
        case .serversAndGPUs: return "\(summary.busyServers)·\(summary.busyGPUs)"
        case .busyOverTotal: return "\(summary.busyServers)/\(summary.gpuServers)"
        case .gpus: return "\(summary.busyGPUs)/\(summary.totalGPUs)"
        case .vram: return "\(Self.gb(summary.vramUsedMiB))/\(Self.gb(summary.vramTotalMiB))G"
        }
    }

    private static func gb(_ mib: Double) -> String { "\(Int((mib / 1024).rounded()))" }
}

/// MenuBarExtra extracts an image/title from its label rather than hosting an
/// arbitrary SwiftUI layout. Draw the complete label as a template image so
/// both rows survive that conversion, at native resolution on each display.
enum MenuBarArtwork {
    static let height: CGFloat = 20

    static func image(values: [String], offline: Bool) -> NSImage {
        let rows = Array(values.prefix(2))
        let stacked = rows.count == 2
        let font = NSFont.monospacedDigitSystemFont(ofSize: stacked ? 9 : 13, weight: stacked ? .medium : .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let widths = rows.map { ceil(($0 as NSString).size(withAttributes: attributes).width) }
        let textWidth = widths.max() ?? 0
        let textX: CGFloat = 22
        let width = rows.isEmpty ? 18 : textX + textWidth
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let icon = offline ? BrandMark.menuBarAlertImage : BrandMark.menuBarImage
            icon.draw(in: CGRect(x: 0, y: 1, width: 18, height: 18))
            for (index, row) in rows.enumerated() {
                let line = NSAttributedString(string: row, attributes: attributes)
                let rowHeight: CGFloat = stacked ? 10 : height
                let rowBottom = stacked && index == 0 ? rowHeight : 0
                let y = rowBottom + (rowHeight - line.size().height) / 2
                line.draw(at: CGPoint(x: textX + (textWidth - widths[index]) / 2, y: y))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
