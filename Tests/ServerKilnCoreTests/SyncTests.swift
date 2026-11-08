import Foundation
import CloudKit
import XCTest
@testable import ServerKilnCore
@testable import ServerKilnSSH
@testable import ServerKilnSync

final class AuthorizedKeysTests: XCTestCase {
    let id = UUID(uuidString: "6B1E2C1A-0000-4000-8000-00000000ABCD")!

    func testMonitorLineIsForcedAndRestricted() {
        let line = AuthorizedKeys.line(publicKey: "ssh-ed25519 AAAAC3Nz comment here", server: id, role: .monitor)
        XCTAssertEqual(line, #"restrict,command="/bin/sh .config/serverkiln/collect.sh" ssh-ed25519 AAAAC3Nz serverkiln:6b1e2c1a-0000-4000-8000-00000000abcd:monitor"#)
    }

    func testTerminalLineAllowsOnlyPty() {
        let line = AuthorizedKeys.line(publicKey: "ssh-ed25519 AAAAC3Nz", server: id, role: .terminal)
        XCTAssertTrue(line.hasPrefix("restrict,pty ssh-ed25519 AAAAC3Nz "))
        XCTAssertFalse(line.contains("command="))
    }

    func testDirectNetcatProxyIsNotAJumpHost() {
        XCTAssertTrue(KeyDeployer.isDirectNetcat("/usr/bin/nc -b en0 %h %p"))
        XCTAssertTrue(KeyDeployer.isDirectNetcat("nc -4 -w 5 %h %p"))
        XCTAssertFalse(KeyDeployer.isDirectNetcat("nc -X 5 -x proxy:1080 %h %p"))
        XCTAssertFalse(KeyDeployer.isDirectNetcat("nc other-host 22"))
        XCTAssertFalse(KeyDeployer.isDirectNetcat("ssh -W h:22 jump"))
        XCTAssertFalse(KeyDeployer.isDirectNetcat("cloudflared access ssh --hostname h"))
    }

    func testParseHostKeysKeepsSupportedTypesOnly() {
        let out = "noise\n@@HOSTKEYS\nssh-ed25519 AAAA root@h\nssh-rsa BBBB root@h\necdsa-sha2-nistp256 CCCC root@h\n@@DONE\n"
        XCTAssertEqual(AuthorizedKeys.parseHostKeys(out), ["ssh-ed25519 AAAA root@h", "ssh-rsa BBBB root@h", "ecdsa-sha2-nistp256 CCCC root@h"])
    }

    /// Runs the generated install / revoke scripts against a scratch `$HOME`:
    /// foreign lines survive, redeploys don't duplicate, revoke cleans up.
    func testInstallIsIdempotentAndRevokeCleansUp() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sk-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ak = home.appendingPathComponent(".ssh/authorized_keys")
        try "ssh-ed25519 USERKEY me@laptop\n".write(to: ak, atomically: true, encoding: .utf8)

        let keys: [KeyRole: String] = [.monitor: SSHIdentity().openSSHPublicKey, .terminal: SSHIdentity().openSSHPublicKey]
        let script = AuthorizedKeys.installScript(server: id, keys: keys)
        _ = try sh(script, home: home)
        let out = try sh(script, home: home)
        XCTAssertTrue(out.contains("@@DONE"))

        let lines = try String(contentsOf: ak, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "ssh-ed25519 USERKEY me@laptop")
        XCTAssertEqual(lines.filter { $0.contains(":monitor") }.count, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: ak.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int), 0o600)
        let collector = home.appendingPathComponent(AuthorizedKeys.collectorPath)
        XCTAssertEqual(try String(contentsOf: collector, encoding: .utf8), RemoteScript.loop)

        _ = try sh(AuthorizedKeys.revokeScript(server: id), home: home)
        XCTAssertEqual(try String(contentsOf: ak, encoding: .utf8), "ssh-ed25519 USERKEY me@laptop\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: collector.path))
    }

    private func sh(_ script: String, home: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

final class HostKeyTests: XCTestCase {
    func testFingerprintMatchesSSHKeygen() throws {
        let identity = SSHIdentity()
        let line = identity.openSSHPublicKey
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID().uuidString).pub")
        try line.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-l", "-f", file.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(printed.contains(HostKey.fingerprint(line)!), printed)
    }

    func testTruncatedRSAIsNotSupported() {
        XCTAssertFalse(HostKey.isSupported("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7"))
        XCTAssertTrue(HostKey.isSupported(SSHIdentity().openSSHPublicKey))
    }

    func testMergeDedupesSameMachineFromTwoMacs() {
        func server(_ name: String, host: String, deployed: TimeInterval, order: Int) -> SyncedServer {
            SyncedServer(id: UUID(), name: name, endpoint: SSHEndpoint(host: host, user: "root", hostKeys: []),
                         roles: [.monitor], order: order, deployedAt: Date(timeIntervalSince1970: deployed))
        }
        let a = SyncedPayload(servers: [server("8x4090", host: "A", deployed: 100, order: 0), server("1x5090", host: "B", deployed: 100, order: 1)],
                              policy: BusyPolicy(utilizationThreshold: 10), macName: "mini", updatedAt: Date(timeIntervalSince1970: 200))
        let b = SyncedPayload(servers: [server("5090 (MBP)", host: "b", deployed: 300, order: 0), server("A800", host: "C", deployed: 50, order: 1)],
                              policy: BusyPolicy(utilizationThreshold: 30), macName: "mbp", updatedAt: Date(timeIntervalSince1970: 400))
        let m = SyncedPayload.merge([a, b])
        XCTAssertEqual(m.servers.map(\.name), ["5090 (MBP)", "A800", "8x4090"], "host match is case-insensitive; newest deploy wins")
        XCTAssertEqual(m.servers.map(\.order), [0, 1, 2])
        XCTAssertEqual(m.policy.utilizationThreshold, 30, "most recently updated Mac's thresholds")
    }

    func testRelayDoesNotDisplaceDirectCredentials() {
        let endpoint = SSHEndpoint(host: "gpu", user: "root", hostKeys: [])
        let direct = SyncedServer(id: UUID(), name: "direct", endpoint: endpoint, roles: [.monitor], deployedAt: .distantPast)
        let relay = SyncedServer(id: UUID(), name: "relay", endpoint: endpoint, roles: [], deployedAt: Date())
        let a = SyncedPayload(servers: [direct], policy: BusyPolicy())
        let b = SyncedPayload(servers: [relay], policy: BusyPolicy())
        XCTAssertEqual(SyncedPayload.merge([a, b]).servers.map(\.id), [direct.id])
        XCTAssertEqual(SyncedPayload.merge([b, a]).servers.map(\.id), [direct.id])
    }

    func testPartialCloudReadMustNotSilentlyDropMac() throws {
        XCTAssertNil(try CloudStore.fetchedRecord(.failure(CKError(.unknownItem))))
        XCTAssertThrowsError(try CloudStore.fetchedRecord(.failure(CKError(.networkFailure))))
        XCTAssertThrowsError(try CloudStore.fetchedRecord(.failure(CKError(.permissionFailure))))
    }

    func testLegacyPayloadCanDecodeWithoutMacID() throws {
        let payload = SyncedPayload(servers: [], policy: BusyPolicy(), macName: "Old Mac")
        let decoded = try JSONDecoder().decode(SyncedPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertNil(decoded.macID)
        XCTAssertEqual(decoded.macName, "Old Mac")
    }

    func testEventDedupNameIsSharedAcrossMacs() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ActivityEvent.dedupName(endpointKey: "root@a:22", kind: .idle, date: t),
                       ActivityEvent.dedupName(endpointKey: "root@a:22", kind: .idle, date: t.addingTimeInterval(30)))
        XCTAssertNotEqual(ActivityEvent.dedupName(endpointKey: "root@a:22", kind: .idle, date: t),
                          ActivityEvent.dedupName(endpointKey: "root@a:22", kind: .busy, date: t))
    }

    func testSyncedServerRoundTrip() throws {
        let s = SyncedServer(id: UUID(), name: "8x4090", endpoint: SSHEndpoint(host: "10.0.0.2", port: 2222, user: "ming", hostKeys: ["ssh-ed25519 AAAA"]),
                             roles: [.monitor], order: 2)
        let back = try JSONDecoder().decode(SyncedServer.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertFalse(back.hasTerminal)
    }
}

/// End-to-end against a throwaway, unprivileged `sshd` on localhost: proves
/// the monitor key can only run the collector, the terminal key gets a shell,
/// and a wrong pinned host key is refused before authentication.
class LocalSSHDTests: XCTestCase {
    var dir: URL!
    var sshd: Process?
    var port = 0
    var hostKey = ""
    let monitor = SSHIdentity()
    let terminal = SSHIdentity()

    /// Host key type for this suite; the RSA subclass reruns everything.
    class var hostKeyArgs: [String] { ["-t", "ed25519"] }

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else { throw XCTSkip("no sshd") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sk-sshd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = dir.appendingPathComponent("host_key").path
        try run("/usr/bin/ssh-keygen", ["-q", "-N", "", "-f", key] + Self.hostKeyArgs)
        hostKey = try String(contentsOfFile: key + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        // The forced command normally runs `$HOME/.config/serverkiln/collect.sh`;
        // point it at a scratch copy so the test never touches the real home.
        let collector = dir.appendingPathComponent("collect.sh")
        try RemoteScript.loop.write(to: collector, atomically: true, encoding: .utf8)
        let id = UUID()
        let monitorLine = AuthorizedKeys.line(publicKey: monitor.openSSHPublicKey, server: id, role: .monitor)
            .replacingOccurrences(of: AuthorizedKeys.collectorPath, with: collector.path)
        let terminalLine = AuthorizedKeys.line(publicKey: terminal.openSSHPublicKey, server: id, role: .terminal)
        let ak = dir.appendingPathComponent("authorized_keys")
        try (monitorLine + "\n" + terminalLine + "\n").write(to: ak, atomically: true, encoding: .utf8)

        port = Int.random(in: 42000...48000)
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(key)
        AuthorizedKeysFile \(ak.path)
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PidFile \(dir.appendingPathComponent("pid").path)
        """
        let cfg = dir.appendingPathComponent("sshd_config")
        try config.write(to: cfg, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        p.arguments = ["-D", "-e", "-f", cfg.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        sshd = p
        Thread.sleep(forTimeInterval: 0.6)
        guard p.isRunning else { throw XCTSkip("sshd could not start unprivileged") }
    }

    override func tearDown() {
        sshd?.terminate()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    var endpoint: SSHEndpoint { SSHEndpoint(host: "127.0.0.1", port: port, user: NSUserName(), hostKeys: [hostKey]) }

    func testMonitorKeyCollects() async throws {
        let c = RemoteCollector(endpoint: endpoint, identity: monitor)
        defer { c.close() }
        let first = try await c.fetch()
        XCTAssertFalse(first.system.hostname.isEmpty)
        let second = try await c.fetch()
        XCTAssertEqual(second.system.hostname, first.system.hostname)
    }

    func testMonitorKeyCannotRunCommandsOrShell() async throws {
        let conn = try await SSHConnection.connect(endpoint, identity: monitor)
        defer { conn.close() }
        let sink = TextSink()
        // The forced command replaces whatever we ask for.
        let ch = try await conn.openSession(command: "echo PWNED; id", pty: nil, sink: sink, timeout: 10)
        var buf = ch.allocator.buffer(capacity: 1)
        buf.writeString("\n")
        try await ch.writeAndFlush(buf).get()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(sink.text.contains("PWNED"))
        XCTAssertTrue(sink.text.contains("@@HOST"))
        // `restrict` denies the pty.
        do {
            _ = try await conn.openSession(command: nil, pty: .init(wantReply: true, term: "xterm", terminalCharacterWidth: 80,
                                                                    terminalRowHeight: 24, terminalPixelWidth: 0,
                                                                    terminalPixelHeight: 0, terminalModes: .init([:])),
                                           sink: TextSink(), timeout: 5)
            XCTFail("pty must be refused for the monitor key")
        } catch {}
    }

    func testTerminalKeyGetsShell() async throws {
        let conn = try await SSHConnection.connect(endpoint, identity: terminal)
        defer { conn.close() }
        let sink = TextSink()
        _ = try await conn.openSession(command: "echo hello-$((40+2))", pty: nil, sink: sink, timeout: 10)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(sink.text.contains("hello-42"))
    }

    func testShellSessionRunsInteractively() async throws {
        let sink = TextSink()
        let shell = try await ShellSession.open(endpoint, identity: terminal, columns: 80, rows: 24,
                                                onData: { sink.received($0) }, onClose: {})
        defer { shell.close() }
        shell.resize(columns: 100, rows: 30)
        shell.send(Data("echo shell-$((6*7)); stty size\n".utf8))
        // Login-shell startup (including user shell plugins) varies with
        // machine load. Wait for output, with a bounded failure deadline.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(sink.text.contains("shell-42") && sink.text.contains("30 100")), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(sink.text.contains("shell-42"), sink.text)
        XCTAssertTrue(sink.text.contains("30 100"), sink.text)
    }

    func testWrongHostKeyIsRejected() async throws {
        var ep = endpoint
        ep.hostKeys = [try wrongHostKey()]
        do {
            _ = try await RemoteCollector(endpoint: ep, identity: monitor).fetch(timeout: 5)
            XCTFail("must refuse an unpinned host key")
        } catch let e as SSHClientError {
            guard case .hostKeyMismatch = e else { return XCTFail("\(e)") }
        }
    }

    func testUnknownKeyIsRejected() async throws {
        do {
            _ = try await RemoteCollector(endpoint: endpoint, identity: SSHIdentity()).fetch(timeout: 5)
            XCTFail("must refuse an unauthorized key")
        } catch let e as SSHClientError {
            XCTAssertEqual(e, .authenticationFailed)
        }
    }

    /// A valid key of the same type as the server's, but not the server's.
    func wrongHostKey() throws -> String {
        let other = dir.appendingPathComponent("other").path
        try run("/usr/bin/ssh-keygen", ["-q", "-N", "", "-f", other] + Self.hostKeyArgs)
        return try String(contentsOfFile: other + ".pub", encoding: .utf8)
    }

    func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }
}

/// Same suite against an RSA-only server (rsa-sha2-512 negotiated).
final class LocalSSHDRSATests: LocalSSHDTests {
    override class var hostKeyArgs: [String] { ["-t", "rsa", "-b", "3072"] }

    func testRSAHostKeyIsSupported() {
        XCTAssertTrue(HostKey.isSupported(hostKey))
    }
}

final class TextSink: SessionSink, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    func received(_ d: Data) { lock.withLock { data.append(d) } }
    func closed() {}
}

final class TaskTrackerTests: XCTestCase {
    func task(_ pid: Int, _ cmd: String, elapsed: Int, gpu: [Int] = []) -> GPUTask {
        GPUTask(pid: pid, user: "ming", elapsedSeconds: elapsed, command: cmd, gpuIndices: gpu, cwd: "/w")
    }

    func testJobLifecycleGroupsRanksAndSurvivesBlips() {
        var t = TaskTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let ranks = (0..<4).map { task(100 + $0, "python train.py --cfg a.yaml --local-rank=\($0)", elapsed: 300, gpu: [$0]) }
        t.observe(ranks, at: t0)
        XCTAssertEqual(t.running.count, 1, "ranks of one job are one record")
        XCTAssertEqual(t.running.values.first?.gpuIndices, [0, 1, 2, 3])
        XCTAssertEqual(t.running.values.first?.startedAt, t0.addingTimeInterval(-300))

        // One missed poll does not end it.
        XCTAssertTrue(t.observe([], at: t0.addingTimeInterval(30)).isEmpty)
        t.observe(ranks.map { var r = $0; r.elapsedSeconds = 360; return r }, at: t0.addingTimeInterval(60))
        XCTAssertEqual(t.running.count, 1)

        // Gone for longer than the grace period: finished, ended at last sighting.
        t.observe([], at: t0.addingTimeInterval(90))
        let ended = t.observe([], at: t0.addingTimeInterval(200))
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(t.last?.endedAt, t0.addingTimeInterval(60))
        XCTAssertEqual(t.last?.duration, 360)
        XCTAssertTrue(t.running.isEmpty)
    }

    func testShortBlipsAreNotJobs() {
        var t = TaskTracker()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        t.observe([task(1, "python quick.py", elapsed: 5)], at: t0)
        t.observe([], at: t0.addingTimeInterval(200))
        XCTAssertNil(t.last)
    }
}
