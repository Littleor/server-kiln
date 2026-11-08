import SwiftUI

/// The kiln silhouette from `BrandMark` as a SwiftUI shape, so iOS, widgets
/// and the Mac draw the same mark. Coordinates are the 1024 pt icon space
/// with y pointing up, mapped into the shape's rect.
public struct KilnShape: Shape {
    public init() {}

    typealias Segment = (to: CGPoint, c1: CGPoint?, c2: CGPoint?)
    static let start = CGPoint(x: 512, y: 276)
    static let left: [Segment] = [
        (CGPoint(x: 318, y: 276), nil, nil),
        (CGPoint(x: 266, y: 330), CGPoint(x: 284, y: 276), CGPoint(x: 266, y: 298)),
        (CGPoint(x: 412, y: 680), CGPoint(x: 266, y: 510), CGPoint(x: 330, y: 610)),
        (CGPoint(x: 426, y: 720), CGPoint(x: 422, y: 690), CGPoint(x: 426, y: 704)),
        (CGPoint(x: 426, y: 772), nil, nil),
        (CGPoint(x: 412, y: 786), CGPoint(x: 416, y: 774), CGPoint(x: 412, y: 780)),
        (CGPoint(x: 424, y: 806), CGPoint(x: 412, y: 798), CGPoint(x: 416, y: 806)),
        (CGPoint(x: 512, y: 806), nil, nil),
    ]
    /// Artwork bounds (x 266...758, y 276...806).
    static let bounds = CGRect(x: 266, y: 276, width: 492, height: 530)

    public func path(in rect: CGRect) -> Path {
        let t = Self.transform(into: rect)
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: 1024 - p.x, y: p.y) }
        var p = Path()
        p.move(to: Self.start.applying(t))
        func add(_ to: CGPoint, _ c1: CGPoint?, _ c2: CGPoint?) {
            if let c1, let c2 { p.addCurve(to: to.applying(t), control1: c1.applying(t), control2: c2.applying(t)) } else { p.addLine(to: to.applying(t)) }
        }
        for s in Self.left { add(s.to, s.c1, s.c2) }
        for i in Self.left.indices.reversed() {
            let from = i == 0 ? Self.start : Self.left[i - 1].to
            add(m(from), Self.left[i].c2.map(m), Self.left[i].c1.map(m))
        }
        p.closeSubpath()
        return p
    }

    /// Fits the artwork bounds into `rect`, flipping y.
    static func transform(into rect: CGRect) -> CGAffineTransform {
        let k = min(rect.width / bounds.width, rect.height / bounds.height)
        let dx = rect.midX - bounds.midX * k
        let dy = rect.midY + bounds.midY * k
        return CGAffineTransform(a: k, b: 0, c: 0, d: -k, tx: dx, ty: dy)
    }
}

/// The glowing oven hatch, drawn in the same space as `KilnShape`.
public struct KilnHatchShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let t = KilnShape.transform(into: rect)
        let r = CGRect(x: 382, y: 276, width: 260, height: 200)
        let radius = r.width / 2
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addArc(center: CGPoint(x: r.midX, y: r.maxY - radius), radius: radius,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p.applying(t)
    }
}

/// Small colour mark: glazed kiln body with an ember-lit hatch.
public struct KilnMark: View {
    public init() {}

    public var body: some View {
        ZStack {
            KilnShape().fill(LinearGradient(colors: [Color(red: 0.97, green: 0.94, blue: 0.90), Color(red: 0.70, green: 0.64, blue: 0.58)],
                                            startPoint: .top, endPoint: .bottom))
            KilnHatchShape().fill(LinearGradient(colors: [Color(red: 1, green: 0.84, blue: 0.48), Color(red: 1, green: 0.36, blue: 0.10)],
                                                 startPoint: .top, endPoint: .bottom))
        }
        .aspectRatio(492.0 / 530.0, contentMode: .fit)
    }
}

/// Brand palette (warm charcoal + ember) shared by the Mac icon and iOS.
public enum Brand {
    public static let ember = Color(red: 1, green: 0.55, blue: 0.2)
    public static let charcoalTop = Color(red: 0.20, green: 0.165, blue: 0.15)
    public static let charcoalBottom = Color(red: 0.075, green: 0.06, blue: 0.055)
}
