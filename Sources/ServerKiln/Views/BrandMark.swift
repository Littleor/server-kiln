import ServerKilnCore
import AppKit
import SwiftUI

/// A bottle kiln: round belly, a neck tapering into the chimney, embers
/// rising from the top. Its low oven hatch glows, with rack units inside, so
/// the mark reads as both a kiln and a server.
enum BrandMark {
    private typealias Segment = (to: CGPoint, c1: CGPoint?, c2: CGPoint?)

    /// Left half of the kiln, from bottom center to chimney-top center, in
    /// the 1024 pt icon space. The right half mirrors it about x = 512.
    private static let kilnStart = CGPoint(x: 512, y: 276)
    private static let kilnLeft: [Segment] = [
        (CGPoint(x: 318, y: 276), nil, nil),
        (CGPoint(x: 266, y: 330), CGPoint(x: 284, y: 276), CGPoint(x: 266, y: 298)),
        (CGPoint(x: 412, y: 680), CGPoint(x: 266, y: 510), CGPoint(x: 330, y: 610)),
        (CGPoint(x: 426, y: 720), CGPoint(x: 422, y: 690), CGPoint(x: 426, y: 704)),
        (CGPoint(x: 426, y: 772), nil, nil),
        (CGPoint(x: 412, y: 786), CGPoint(x: 416, y: 774), CGPoint(x: 412, y: 780)),
        (CGPoint(x: 424, y: 806), CGPoint(x: 412, y: 798), CGPoint(x: 416, y: 806)),
        (CGPoint(x: 512, y: 806), nil, nil),
    ]

    private static func kiln() -> NSBezierPath {
        func mirror(_ p: CGPoint) -> CGPoint { CGPoint(x: 1024 - p.x, y: p.y) }
        func add(_ path: NSBezierPath, _ to: CGPoint, _ c1: CGPoint?, _ c2: CGPoint?) {
            if let c1, let c2 { path.curve(to: to, controlPoint1: c1, controlPoint2: c2) } else { path.line(to: to) }
        }
        let path = NSBezierPath()
        path.move(to: kilnStart)
        for seg in kilnLeft { add(path, seg.to, seg.c1, seg.c2) }
        for i in kilnLeft.indices.reversed() {
            let from = i == 0 ? kilnStart : kilnLeft[i - 1].to
            add(path, mirror(from), kilnLeft[i].c2.map(mirror), kilnLeft[i].c1.map(mirror))
        }
        path.close()
        return path
    }

    /// Round-topped arch whose legs stand on `rect.minY`.
    private static func arch(_ rect: CGRect, closed: Bool) -> NSBezierPath {
        let r = rect.width / 2
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.maxY - r), radius: r,
                       startAngle: 180, endAngle: 0, clockwise: true)
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
        if closed { path.close() }
        return path
    }

    /// The oven hatch: a low arch, wider than it is tall.
    private static let hatchRect = CGRect(x: 382, y: 276, width: 260, height: 200)

    /// Line glyph for the menu bar, drawn from the same kiln outline. Both
    /// states share an 18 pt canvas to keep metrics stationary.
    private static func menuBarImage(alert: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // Map the 1024 pt artwork (x 266...758, y 276...806) onto the glyph.
            let k: CGFloat = 0.0285
            let t = AffineTransform(m11: k, m12: 0, m21: 0, m22: k, tX: 9 - 512 * k, tY: 1.5 - 276 * k)
            let body = kiln()
            body.transform(using: t)
            body.lineWidth = 1.5
            body.lineJoinStyle = .round
            body.stroke()
            // The glowing hatch, with two rack slots knocked out of it.
            let hatch = arch(hatchRect, closed: true)
            hatch.transform(using: t)
            hatch.fill()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            for y in [2.85, 4.75] {
                NSBezierPath(roundedRect: CGRect(x: 7.1, y: y, width: 3.8, height: 0.9),
                             xRadius: 0.45, yRadius: 0.45).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            if alert {
                let dot = NSBezierPath(ovalIn: CGRect(x: 13, y: 0.5, width: 4, height: 4))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                dot.lineWidth = 2
                dot.stroke()
                NSGraphicsContext.restoreGraphicsState()
                dot.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = alert ? String(appLocalized: "ServerKiln，有服务器离线") : "ServerKiln"
        return image
    }

    static let menuBarImage = menuBarImage(alert: false)
    static let menuBarAlertImage = menuBarImage(alert: true)

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }

    /// Resolution-independent artwork, rasterized directly at every icon size.
    /// `fullBleed` draws the tile edge to edge with no shadow, for iOS where
    /// the system applies its own mask and alpha is not allowed.
    static func appIcon(pixels: Int, fullBleed: Bool = false) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let scale = CGFloat(pixels) / (fullBleed ? 824 : 1024)
        NSGraphicsContext.current?.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        if fullBleed { transform.translateX(by: -100, yBy: -100) }
        transform.concat()
        let detailed = pixels >= 64

        // Tile: warm charcoal, lit from above.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let corner: CGFloat = fullBleed ? 0 : 184
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        rgb(0.08, 0.065, 0.06).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        tilePath.addClip()
        NSGradient(colors: [rgb(0.20, 0.165, 0.15), rgb(0.075, 0.06, 0.055)])!.draw(in: tile, angle: -90)
        // Ember light pooling on the floor in front of the hatch.
        NSGradient(starting: rgb(1, 0.45, 0.15, 0.30), ending: rgb(1, 0.45, 0.15, 0))!
            .draw(fromCenter: CGPoint(x: 512, y: 230), radius: 0,
                  toCenter: CGPoint(x: 512, y: 230), radius: 420, options: [])
        NSGraphicsContext.restoreGraphicsState()

        if !fullBleed {
            let border = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 182, yRadius: 182)
            border.lineWidth = 2
            NSColor.white.withAlphaComponent(0.10).setStroke()
            border.stroke()
        }

        // Contact shadow grounding the kiln.
        NSGradient(starting: NSColor.black.withAlphaComponent(0.45), ending: NSColor.black.withAlphaComponent(0))!
            .draw(in: NSBezierPath(ovalIn: CGRect(x: 236, y: 244, width: 552, height: 64)), relativeCenterPosition: .zero)

        // Body: glazed clay with a darker glaze band across the shoulder.
        let body = kiln()
        NSGraphicsContext.saveGraphicsState()
        let bodyShadow = NSShadow()
        bodyShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        bodyShadow.shadowBlurRadius = 28
        bodyShadow.shadowOffset = NSSize(width: 0, height: -10)
        bodyShadow.set()
        rgb(0.86, 0.81, 0.75).setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        NSGradient(colors: [rgb(0.70, 0.64, 0.58), rgb(0.88, 0.83, 0.77), rgb(0.97, 0.94, 0.90)],
                   atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!.draw(in: body, angle: 90)
        // Side shading rounds the belly.
        NSGradient(colors: [rgb(0.35, 0.28, 0.24, 0.30), rgb(0.35, 0.28, 0.24, 0), rgb(0.35, 0.28, 0.24, 0),
                            rgb(0.35, 0.28, 0.24, 0.38)],
                   atLocations: [0, 0.28, 0.62, 1], colorSpace: .deviceRGB)!.draw(in: body, angle: 0)
        let band = CGRect(x: 0, y: 560, width: 1024, height: 34)
        NSGradient(starting: rgb(0.55, 0.30, 0.20), ending: rgb(0.72, 0.42, 0.28))!.draw(in: band, angle: 90)
        if detailed {
            // Glaze highlight on the upper left of the belly.
            NSGradient(starting: NSColor.white.withAlphaComponent(0.5), ending: NSColor.white.withAlphaComponent(0))!
                .draw(fromCenter: CGPoint(x: 380, y: 500), radius: 0,
                      toCenter: CGPoint(x: 380, y: 500), radius: 190, options: [])
        }
        NSGraphicsContext.restoreGraphicsState()

        // Hatch: ember glow, hottest at the floor.
        let hatch = arch(hatchRect, closed: true)
        NSGradient(colors: [rgb(1, 0.36, 0.10), rgb(1, 0.58, 0.20), rgb(1, 0.84, 0.48)],
                   atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!.draw(in: hatch, angle: 90)
        if detailed {
            // Inner rim shadow gives the opening depth.
            NSGraphicsContext.saveGraphicsState()
            hatch.addClip()
            let rim = arch(hatchRect.insetBy(dx: -14, dy: 0).offsetBy(dx: 0, dy: 10), closed: false)
            rim.lineWidth = 36
            rgb(0.45, 0.12, 0.03, 0.35).setStroke()
            rim.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Rack units silhouetted against the fire, each with a status light.
        for y: CGFloat in [302, 370] {
            let unit = CGRect(x: 426, y: y, width: 172, height: 46)
            rgb(0.16, 0.08, 0.05, 0.92).setFill()
            NSBezierPath(roundedRect: unit, xRadius: 12, yRadius: 12).fill()
            if detailed {
                let led = CGRect(x: unit.maxX - 34, y: unit.midY - 8, width: 16, height: 16)
                rgb(1, 0.80, 0.42).setFill()
                NSBezierPath(ovalIn: led).fill()
                rgb(1, 0.70, 0.35, 0.45).setFill()
                for x: CGFloat in [unit.minX + 22, unit.minX + 50] {
                    NSBezierPath(roundedRect: CGRect(x: x, y: unit.midY - 5, width: 18, height: 10),
                                 xRadius: 5, yRadius: 5).fill()
                }
            }
        }

        // Embers drifting up from the chimney.
        NSGradient(starting: rgb(1, 0.55, 0.2, 0.35), ending: rgb(1, 0.55, 0.2, 0))!
            .draw(fromCenter: CGPoint(x: 512, y: 812), radius: 0,
                  toCenter: CGPoint(x: 512, y: 812), radius: 110, options: [])
        for (x, y, r) in [(498.0, 848.0, 13.0), (536.0, 878.0, 9.0), (508.0, 902.0, 6.0)] as [(CGFloat, CGFloat, CGFloat)] {
            rgb(1, 0.72, 0.36).setFill()
            NSBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
        }
        return rep
    }

    static func writeIconset(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                let data = appIcon(pixels: base * scale).representation(using: .png, properties: [:])!
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}
