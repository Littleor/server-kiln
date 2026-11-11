#if os(macOS)
import Foundation
import ServerKilnCore
import ServerKilnSSH

/// Installs, verifies and revokes the iPhone's dedicated keys (PRD F9.1/F9.2).
/// Everything runs over the user's own `ssh` — the trusted channel — so the
/// host keys we pin come from an authenticated session, never from a scan.
public enum KeyDeployer {
    public enum DeployError: Error, LocalizedError {
        case proxy
        case unresolved
        case noSupportedHostKey
        case remote(String)

        public var errorDescription: String? {
            switch self {
            case .proxy: return String(appLocalized: "该服务器需要跳板机（ProxyJump / ProxyCommand），iPhone 无法直连")
            case .unresolved: return String(appLocalized: "无法解析 SSH 配置（ssh -G 失败）")
            case .noSupportedHostKey: return String(appLocalized: "服务器没有 Ed25519 / ECDSA 主机密钥，iPhone 无法安全校验")
            case let .remote(m): return m
            }
        }
    }

    /// Effective connection parameters from `ssh -G`, so aliases, `User`,
    /// `Port` and `HostName` from `~/.ssh/config` are honoured.
    public struct Resolved: Sendable {
        public var host: String
        public var port: Int
        public var user: String
        public var usesProxy: Bool
    }

    public static func resolve(_ server: ServerConfig) async throws -> Resolved {
        var args = ["-G"]
        if let port = server.port { args += ["-p", String(port)] }
        args.append(server.target)
        let out = try await Shell.run("/usr/bin/ssh", args)
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, map[String(parts[0])] == nil { map[String(parts[0])] = String(parts[1]) }
        }
        guard let host = map["hostname"], let user = map["user"] else { throw DeployError.unresolved }
        let jump = map["proxyjump"].map { $0 != "none" } ?? false
        let command = map["proxycommand"].map { $0 != "none" && !isDirectNetcat($0) } ?? false
        return Resolved(host: host, port: Int(map["port"] ?? "22") ?? 22, user: user, usesProxy: jump || command)
    }

    /// `nc [-b iface | -s addr | -4 | -6 | -w n] %h %p` only picks how the Mac
    /// reaches the host; the phone can still connect to `%h:%p` directly.
    static func isDirectNetcat(_ command: String) -> Bool {
        var words = command.split(separator: " ").map(String.init)
        guard let tool = words.first, ["nc", "ncat", "netcat"].contains((tool as NSString).lastPathComponent) else { return false }
        words.removeFirst()
        // Must end in exactly `%h %p` (as `ssh -G` prints it) — anything else
        // may reach a different host than the phone would.
        guard words.suffix(2) == ["%h", "%p"] else { return false }
        words.removeLast(2)
        var i = 0
        while i < words.count {
            switch words[i] {
            case "-4", "-6": i += 1
            case "-b", "-s", "-w": i += 2
            default: return false
            }
        }
        return i == words.count
    }

    /// Full deployment. Returns the record to sync; on any failure after the
    /// remote edit, the remote lines and local keys are rolled back.
    public static func deploy(_ server: ServerConfig, includeTerminal: Bool, order: Int,
                              progress: @Sendable (String) -> Void = { _ in }) async throws -> SyncedServer {
        progress(String(appLocalized: "解析 SSH 配置…"))
        let resolved = try await resolve(server)
        if resolved.usesProxy { throw DeployError.proxy }

        progress(String(appLocalized: "生成专属密钥…"))
        var identities: [KeyRole: SSHIdentity] = [.monitor: SSHIdentity()]
        if includeTerminal { identities[.terminal] = SSHIdentity() }

        progress(String(appLocalized: "写入服务器 authorized_keys…"))
        let script = AuthorizedKeys.installScript(server: server.id, keys: identities.mapValues(\.openSSHPublicKey))
        let out: String
        do {
            out = try await SSHRunner.run(SSHRunner.arguments(for: server, connectTimeout: 10), stdin: script, timeout: 30)
        } catch {
            throw DeployError.remote(String(appLocalized: "写入失败：\(error.localizedDescription)"))
        }
        guard out.contains("@@DONE") else { throw DeployError.remote(String(appLocalized: "服务器返回无法识别")) }

        do {
            var hostKeys = AuthorizedKeys.parseHostKeys(out).filter(HostKey.isSupported)
            if hostKeys.isEmpty { hostKeys = try await knownHostKeys(resolved).filter(HostKey.isSupported) }
            guard !hostKeys.isEmpty else { throw DeployError.noSupportedHostKey }

            let endpoint = SSHEndpoint(host: resolved.host, port: resolved.port, user: resolved.user, hostKeys: hostKeys)
            progress(String(appLocalized: "用新密钥验证连接…"))
            // Exactly the code path the phone uses: pinned host key + monitor key.
            let collector = RemoteCollector(endpoint: endpoint, identity: identities[.monitor]!)
            defer { collector.close() }
            let snap = try await collector.fetch(timeout: 20)
            guard !snap.system.hostname.isEmpty else { throw DeployError.remote(String(appLocalized: "验证采集没有返回数据")) }

            progress(String(appLocalized: "保存到 iCloud 钥匙串…"))
            for (role, identity) in identities {
                try KeyVault.store(identity, server: server.id, role: role, label: server.name)
            }
            if !includeTerminal { try? KeyVault.delete(server: server.id, role: .terminal) }
            return SyncedServer(id: server.id, name: server.name, endpoint: endpoint, roles: Set(identities.keys),
                                order: order, muted: server.muted)
        } catch {
            _ = try? await SSHRunner.run(SSHRunner.arguments(for: server), stdin: AuthorizedKeys.revokeScript(server: server.id), timeout: 20)
            for role in KeyRole.allCases { try? KeyVault.delete(server: server.id, role: role) }
            throw error
        }
    }

    /// Removes the remote lines and the keys. Local keys are deleted even if
    /// the server is unreachable, so a lost phone can be cut off right away
    /// from the keychain side; the remote lines are reported as pending.
    @discardableResult
    public static func revoke(_ server: ServerConfig) async -> Error? {
        for role in KeyRole.allCases { try? KeyVault.delete(server: server.id, role: role) }
        do {
            let out = try await SSHRunner.run(SSHRunner.arguments(for: server), stdin: AuthorizedKeys.revokeScript(server: server.id), timeout: 20)
            return out.contains("@@DONE") ? nil : DeployError.remote(String(appLocalized: "服务器返回无法识别"))
        } catch {
            return error
        }
    }

    /// Fallback when `/etc/ssh/*.pub` is unreadable: the Mac's own trusted
    /// `known_hosts` entries for this host.
    static func knownHostKeys(_ r: Resolved) async throws -> [String] {
        let name = r.port == 22 ? r.host : "[\(r.host)]:\(r.port)"
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts").path
        guard let out = try? await Shell.run("/usr/bin/ssh-keygen", ["-F", name, "-f", file]) else { return [] }
        return out.split(separator: "\n").compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 3 else { return nil }
            return "\(parts[1]) \(parts[2])"
        }
    }
}

enum Shell {
    static func run(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: String(decoding: data, as: UTF8.self))
                } else {
                    cont.resume(throwing: KeyDeployer.DeployError.unresolved)
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
#endif
