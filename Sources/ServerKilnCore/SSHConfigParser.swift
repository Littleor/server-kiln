import Foundation

public struct SSHHostEntry: Hashable, Identifiable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var sourceFile: String

    public var id: String { alias }

    public var summary: String {
        var s = ""
        if let user { s += "\(user)@" }
        s += hostName ?? alias
        if let port, port != 22 { s += ":\(port)" }
        return s
    }
}

/// Minimal `~/.ssh/config` reader used for the "import servers" flow. It does
/// not need to fully emulate ssh: the alias is what we pass to `ssh` later.
public enum SSHConfigParser {
    /// Hosts that are almost certainly not compute servers.
    static let ignoredHosts: Set<String> = [
        "github.com", "gitlab.com", "bitbucket.org", "ssh.github.com", "gitee.com", "codeup.aliyun.com",
    ]

    public static func loadDefault() -> [SSHHostEntry] {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
        return load(path: path)
    }

    public static func load(path: String, depth: Int = 0) -> [SSHHostEntry] {
        guard depth < 5, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text, sourceFile: path, depth: depth)
    }

    public static func parse(_ text: String, sourceFile: String = "", depth: Int = 0) -> [SSHHostEntry] {
        var entries: [SSHHostEntry] = []
        var current: [SSHHostEntry] = []

        func flush() {
            entries.append(contentsOf: current)
            current = []
        }

        for raw in text.split(separator: "\n") {
            var line = String(raw)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmed
            guard !line.isEmpty else { continue }

            let (key, value) = splitKeyValue(line)
            switch key.lowercased() {
            case "host":
                flush()
                current = value.split(separator: " ").map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                    .filter { !ignoredHosts.contains($0.lowercased()) }
                    .map { SSHHostEntry(alias: $0, sourceFile: sourceFile) }
            case "match":
                flush()
            case "hostname":
                for i in current.indices where current[i].hostName == nil { current[i].hostName = value }
            case "user":
                for i in current.indices where current[i].user == nil { current[i].user = value }
            case "port":
                for i in current.indices where current[i].port == nil { current[i].port = Int(value) }
            case "include" where current.isEmpty:
                for pattern in value.split(separator: " ") {
                    for file in expandInclude(String(pattern)) {
                        entries.append(contentsOf: load(path: file, depth: depth + 1))
                    }
                }
            default:
                break
            }
        }
        flush()

        // Deduplicate by alias, first definition wins (same as ssh).
        var seen = Set<String>()
        return entries.filter { seen.insert($0.alias).inserted }
    }

    static func splitKeyValue(_ line: String) -> (String, String) {
        if let idx = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) {
            let key = String(line[..<idx])
            var value = String(line[idx...]).trimmed
            if value.hasPrefix("=") { value = String(value.dropFirst()).trimmed }
            value = value.replacingOccurrences(of: "\"", with: "")
            return (key, value)
        }
        return (line, "")
    }

    static func expandInclude(_ pattern: String) -> [String] {
        var p = (pattern as NSString).expandingTildeInPath
        if !p.hasPrefix("/") {
            p = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/" + p)
        }
        guard p.contains("*") || p.contains("?") else { return [p] }
        let dir = (p as NSString).deletingLastPathComponent
        let filePattern = (p as NSString).lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.sorted().filter { fnmatch(filePattern, $0, 0) == 0 }.map { (dir as NSString).appendingPathComponent($0) }
    }
}
