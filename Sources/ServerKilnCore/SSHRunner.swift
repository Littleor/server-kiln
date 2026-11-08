import Foundation

public enum SSHError: Error, LocalizedError, Sendable {
    case timeout
    case failed(code: Int32, message: String)
    case launch(String)
    case sessionClosed

    public var errorDescription: String? {
        switch self {
        case .timeout: return String(appLocalized: "连接超时")
        case .sessionClosed: return String(appLocalized: "连接已断开")
        case let .failed(code, message):
            let m = message.trimmed
            return m.isEmpty ? String(appLocalized: "ssh 退出码 \(code)") : m
        case let .launch(m): return m
        }
    }
}

/// Runs the remote collection script through the system `ssh` binary so that
/// the user's config, keys, agent and ProxyCommand all just work.
public enum SSHRunner {}

#if os(macOS)
public extension SSHRunner {
    static var controlDir: String = {
        // Unix socket paths are limited to ~104 bytes, so NSTemporaryDirectory() is too long.
        let dir = "/tmp/serverkiln-\(getuid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()

    /// Options shared by one-off fetches and long-lived sessions. Never
    /// prompts, never forwards anything, and compresses the text stream.
    static func baseArguments(for server: ServerConfig, connectTimeout: Int = 8) -> [String] {
        var args = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "Compression=yes",
            "-o", "LogLevel=ERROR",
        ]
        if let port = server.port { args += ["-p", String(port)] }
        return args
    }

    /// One-off fetch (e.g. "test connection"); reuses a short-lived master.
    static func arguments(for server: ServerConfig, connectTimeout: Int = 8) -> [String] {
        baseArguments(for: server, connectTimeout: connectTimeout) + [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDir)/%C",
            "-o", "ControlPersist=60",
            server.target, "sh", "-s",
        ]
    }

    /// Fetches and parses a snapshot. Throws `SSHError` on failure.
    static func fetch(_ server: ServerConfig, timeout: TimeInterval = 20) async throws -> ServerSnapshot {
        let out = try await run(arguments(for: server), stdin: RemoteScript.source, timeout: timeout)
        guard out.contains("@@HOST") else {
            throw SSHError.failed(code: 0, message: String(appLocalized: "远端输出无法识别"))
        }
        return SnapshotParser.parse(out)
    }

    static func run(_ args: [String], stdin: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = args
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe

            let state = RunState()
            // Drain pipes concurrently so large outputs can't deadlock.
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                state.outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                state.errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            p.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    guard state.finish() else { return }
                    if proc.terminationReason == .uncaughtSignal && state.timedOut {
                        cont.resume(throwing: SSHError.timeout)
                    } else if proc.terminationStatus != 0 {
                        let err = String(decoding: state.errData, as: UTF8.self)
                        cont.resume(throwing: SSHError.failed(code: proc.terminationStatus, message: lastMeaningfulLine(err)))
                    } else {
                        cont.resume(returning: String(decoding: state.outData, as: UTF8.self))
                    }
                }
            }

            do {
                try p.run()
            } catch {
                _ = state.finish()
                cont.resume(throwing: SSHError.launch(error.localizedDescription))
                return
            }
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning {
                    state.timedOut = true
                    p.terminate()
                }
            }
        }
    }

}
#endif

public extension SSHRunner {
    static func lastMeaningfulLine(_ s: String) -> String {
        let lines = s.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last ?? ""
    }
}

#if os(macOS)
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var _timedOut = false
    private var _out = Data()
    private var _err = Data()

    var outData: Data {
        get { lock.withLock { _out } }
        set { lock.withLock { _out = newValue } }
    }

    var errData: Data {
        get { lock.withLock { _err } }
        set { lock.withLock { _err = newValue } }
    }

    var timedOut: Bool {
        get { lock.withLock { _timedOut } }
        set { lock.withLock { _timedOut = newValue } }
    }

    /// Returns true exactly once.
    func finish() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
#endif
