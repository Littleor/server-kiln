import Foundation

public enum Format {
    /// "3d 4h", "5h 12m", "42m", "30s"
    public static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    public static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// MiB -> "12.3G" / "512M"
    public static func mib(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v >= 1024 { return String(format: "%.1fG", v / 1024) }
        return "\(Int(v))M"
    }

    /// Bytes/second -> "0", "820K", "12M", "1.2G" (no unit suffix "/s").
    public static func rate(_ bytesPerSecond: Double?) -> String {
        guard let b = bytesPerSecond else { return "—" }
        if b < 1024 { return "\(Int(b))B" }
        let k = b / 1024
        if k < 1000 { return "\(Int(k.rounded()))K" }
        let m = k / 1024
        if m < 10 { return String(format: "%.1fM", m) }
        if m < 1000 { return "\(Int(m.rounded()))M" }
        return String(format: "%.1fG", m / 1024)
    }

    /// KB -> "123G" / "1.5T"
    public static func kb(_ v: Double?) -> String {
        guard let v else { return "—" }
        let gb = v / 1024 / 1024
        if gb >= 1024 { return String(format: "%.1fT", gb / 1024) }
        if gb >= 10 { return "\(Int(gb.rounded()))G" }
        return String(format: "%.1fG", gb)
    }
}
