import Foundation
import ServerKilnCore

/// Builds the remote shell snippets that install / revoke the dedicated keys.
/// Pure string generation so it can be unit-tested; executed by the Mac over
/// the user's own, already trusted, ssh connection.
public enum AuthorizedKeys {
    /// Marker comment that identifies our lines, e.g. `serverkiln:<uuid>:monitor`.
    public static func marker(_ server: UUID, _ role: KeyRole) -> String {
        "serverkiln:\(server.uuidString.lowercased()):\(role.rawValue)"
    }

    static func markerPrefix(_ server: UUID) -> String {
        "serverkiln:\(server.uuidString.lowercased()):"
    }

    /// Remote path of the collector, relative to `$HOME`.
    public static let collectorPath = ".config/serverkiln/collect.sh"

    /// The `authorized_keys` options for a role. `restrict` (OpenSSH ≥ 7.2)
    /// disables every forwarding, the pty and `~/.ssh/rc`; the monitor key is
    /// further pinned to the collector (sshd runs it from `$HOME`).
    static func options(_ role: KeyRole) -> String {
        switch role {
        case .monitor: return #"restrict,command="/bin/sh \#(collectorPath)""#
        case .terminal: return "restrict,pty"
        }
    }

    /// One `authorized_keys` line.
    public static func line(publicKey: String, server: UUID, role: KeyRole) -> String {
        let key = publicKey.split(separator: " ").prefix(2).joined(separator: " ")
        return "\(options(role)) \(key) \(marker(server, role))"
    }

    /// Writes the collector, replaces this server's lines and prints the
    /// host public keys between `@@HOSTKEYS` and `@@DONE`.
    public static func installScript(server: UUID, keys: [KeyRole: String]) -> String {
        let collector = Data(RemoteScript.loop.utf8).base64EncodedString()
        let lines = KeyRole.allCases.compactMap { role in keys[role].map { line(publicKey: $0, server: server, role: role) } }
        // Lines travel base64-encoded so no quoting can break the shell.
        let payload = Data((lines.joined(separator: "\n") + "\n").utf8).base64EncodedString()
        return """
        set -e
        umask 077
        mkdir -p "$HOME/.ssh" "$HOME/.config/serverkiln"
        chmod 700 "$HOME/.ssh"
        echo '\(collector)' | base64 -d > "$HOME/\(collectorPath).tmp"
        chmod 700 "$HOME/\(collectorPath).tmp"
        mv -f "$HOME/\(collectorPath).tmp" "$HOME/\(collectorPath)"
        ak="$HOME/.ssh/authorized_keys"
        touch "$ak"
        tmp="$HOME/.ssh/.serverkiln.$$"
        grep -v -F '\(markerPrefix(server))' "$ak" > "$tmp" || true
        echo '\(payload)' | base64 -d >> "$tmp"
        # Rewrite in place to keep the file's owner, mode and SELinux label.
        cat "$tmp" > "$ak"
        rm -f "$tmp"
        chmod 600 "$ak"
        echo "@@HOSTKEYS"
        # The running sshd's own HostKey files (user-level sshd in containers),
        # then the system ones.
        for f in $(ps -eo args 2>/dev/null | awk '/sshd/ { for (i = 1; i < NF; i++) if ($i == "-f") print $(i + 1) }' | sort -u); do
          awk 'tolower($1) == "hostkey" { print $2 ".pub" }' "$f" 2>/dev/null | while read -r k; do cat "$k" 2>/dev/null; done
        done
        cat /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub 2>/dev/null || true
        echo "@@DONE"
        """
    }

    /// Version of the collector the phone's monitor key runs; bump-free:
    /// derived from the script text itself.
    public static var collectorVersion: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in RemoteScript.loop.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Rewrites only `collect.sh` (keys untouched), so a newer app's
    /// collector reaches the phone without redeploying keys.
    public static func updateCollectorScript() -> String {
        let collector = Data(RemoteScript.loop.utf8).base64EncodedString()
        return """
        set -e
        umask 077
        [ -f "$HOME/\(collectorPath)" ] || { echo "@@DONE"; exit 0; }
        echo '\(collector)' | base64 -d > "$HOME/\(collectorPath).tmp"
        chmod 700 "$HOME/\(collectorPath).tmp"
        mv -f "$HOME/\(collectorPath).tmp" "$HOME/\(collectorPath)"
        echo "@@DONE"
        """
    }

    /// Removes this server's lines; drops the collector once no lines of ours remain.
    public static func revokeScript(server: UUID) -> String {
        """
        set -e
        ak="$HOME/.ssh/authorized_keys"
        if [ -f "$ak" ]; then
          tmp="$HOME/.ssh/.serverkiln.$$"
          grep -v -F '\(markerPrefix(server))' "$ak" > "$tmp" || true
          cat "$tmp" > "$ak"
          rm -f "$tmp"
          grep -q -F 'serverkiln:' "$ak" || rm -f "$HOME/\(collectorPath)"
        fi
        echo "@@DONE"
        """
    }

    /// Host key lines printed by `installScript`.
    public static func parseHostKeys(_ output: String) -> [String] {
        guard let start = output.range(of: "@@HOSTKEYS\n") else { return [] }
        return output[start.upperBound...].split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .prefix { $0 != "@@DONE" }
            .filter { $0.hasPrefix("ssh-ed25519 ") || $0.hasPrefix("ecdsa-sha2-") || $0.hasPrefix("ssh-rsa ") }
    }
}
