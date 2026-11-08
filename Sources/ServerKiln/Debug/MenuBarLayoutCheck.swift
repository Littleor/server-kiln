import AppKit

/// `ServerKiln --snapshot /tmp/shots --check-menubar` uses isolated preferences.
@MainActor
enum MenuBarLayoutCheck {
    static func run() {
        checkPreferences()
        let summary = Monitor.Summary(busyServers: 3, gpuServers: 5, busyGPUs: 14, totalGPUs: 18,
                                      vramUsedMiB: 412 * 1024, vramTotalMiB: 640 * 1024)
        let expected: [MenuBarStyle: String] = [.servers: "3", .serversAndGPUs: "3·14", .busyOverTotal: "3/5",
                                               .gpus: "14/18", .vram: "412/640G"]
        for style in MenuBarStyle.allCases {
            precondition(style.text(summary) == expected[style], "Incorrect metric: \(style)")
            let single = MenuBarArtwork.image(values: [style.text(summary)], offline: false)
            precondition(single.size.height == 20)
            for second in MenuBarStyle.allCases {
                let values = [style.text(summary), second.text(summary)]
                let online = MenuBarArtwork.image(values: values, offline: false)
                let offline = MenuBarArtwork.image(values: values, offline: true)
                precondition(online.size == offline.size && online.size.height == 20)
                precondition(online.isTemplate && offline.isTemplate)
                for scale in [1, 2] { checkRows(online, scale: scale) }
            }
        }
        let icon = MenuBarArtwork.image(values: [], offline: false)
        precondition(icon.size == NSSize(width: 18, height: 20))
        checkRows(MenuBarArtwork.image(values: ["123/999", "123456/999999G"], offline: true), scale: 2)
        print("PASS: five metric formats, all 25 row combinations at 1×/2×, large values, empty state and offline canvas.")
    }

    private static func checkPreferences() {
        let suite = "cn.littleor.serverkiln.menubar-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MenuBarStyle.gpus.rawValue, forKey: "menuBarStyle")
        let legacy = AppSettings(defaults: defaults)
        precondition(legacy.menuBarStyle == .gpus && !legacy.menuBarDualRow && legacy.menuBarSecondStyle == .vram)
        legacy.menuBarDualRow = true
        legacy.menuBarStyle = .busyOverTotal
        legacy.menuBarSecondStyle = .serversAndGPUs
        let restored = AppSettings(defaults: defaults)
        precondition(restored.menuBarDualRow && restored.menuBarStyle == .busyOverTotal && restored.menuBarSecondStyle == .serversAndGPUs)
        restored.menuBarDualRow = false
        precondition(AppSettings(defaults: defaults).menuBarSecondStyle == .serversAndGPUs)
        defaults.set("unknown-future-style", forKey: "menuBarSecondStyle")
        precondition(AppSettings(defaults: defaults).menuBarSecondStyle == .vram)
        print("PASS: legacy preferences preserved; row choices survive reload and layout switching; invalid values fall back safely.")
    }

    private static func checkRows(_ image: NSImage, scale: Int) {
        let width = Int(image.size.width) * scale
        let height = Int(image.size.height) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(scale))
        transform.concat()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        for band in [0..<(height / 2), (height / 2)..<height] {
            let ink = band.reduce(0) { total, y in
                total + (22 * scale..<width).filter { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
            }
            precondition(ink > 0, "A text row disappeared at \(scale)×")
        }
    }
}
