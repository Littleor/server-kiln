import ServerKilnCore
import Foundation
import Security
import ServerKilnSSH

/// Dedicated private keys in the iCloud keychain.
///
/// Items are synchronizable (end-to-end encrypted by iCloud Keychain) and
/// readable only after first unlock. Monitor keys live in an access group
/// shared with the widget; terminal keys in a group only the two apps hold,
/// so the widget process cannot read a shell-capable key at all.
public enum KeyVault {
    /// `$(AppIdentifierPrefix)cn.littleor.serverkiln.<suffix>`, matching the
    /// entitlements. The team prefix comes from Info.plist; nil when unsigned.
    public static func accessGroup(_ role: KeyRole) -> String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty else { return nil }
        return prefix + (role == .monitor ? "cn.littleor.serverkiln.shared" : "cn.littleor.serverkiln.terminal")
    }

    static func service(_ role: KeyRole) -> String { "cn.littleor.serverkiln.key.\(role.rawValue)" }

    public enum VaultError: Error, LocalizedError {
        case status(OSStatus)
        case missing

        public var errorDescription: String? {
            switch self {
            case .missing: return String(appLocalized: "钥匙串中没有该服务器的密钥（iCloud 钥匙串可能尚未同步）")
            case let .status(s): return (SecCopyErrorMessageString(s, nil) as String?) ?? String(appLocalized: "钥匙串错误 \(s)")
            }
        }
    }

    private static func baseQuery(_ server: UUID, _ role: KeyRole) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(role),
            kSecAttrAccount as String: server.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group = accessGroup(role) { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    public static func store(_ identity: SSHIdentity, server: UUID, role: KeyRole, label: String) throws {
        try? delete(server: server, role: role)
        var q = baseQuery(server, role)
        q[kSecValueData as String] = identity.rawRepresentation
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecAttrLabel as String] = "ServerKiln · \(label) · \(role == .monitor ? String(appLocalized: "监控") : String(appLocalized: "终端"))"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.status(status) }
    }

    public static func load(server: UUID, role: KeyRole) throws -> SSHIdentity {
        var q = baseQuery(server, role)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { throw VaultError.missing }
        guard status == errSecSuccess, let data = out as? Data else { throw VaultError.status(status) }
        return try SSHIdentity(rawRepresentation: data)
    }

    public static func contains(server: UUID, role: KeyRole) -> Bool {
        var q = baseQuery(server, role)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(server: UUID, role: KeyRole) throws {
        let status = SecItemDelete(baseQuery(server, role) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.status(status) }
    }
}
