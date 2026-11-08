import Foundation

#if os(macOS)

/// A long-lived `ssh` process per server running `RemoteScript.loop`.
///
/// Each `fetch` writes one newline and reads until `@@END`, so a refresh is a
/// single round-trip on an already-authenticated channel: no new local
/// process, no new TCP/SSH handshake and no new remote shell per poll. The
/// session restarts transparently if it dies (network change, sleep, reboot).
public final class SSHSession: @unchecked Sendable {
    public let server: ServerConfig
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var errBuffer = Data()
    private var pending: CheckedContinuation<String, Error>?
    /// Identifies the in-flight request so a stale timeout timer from an
    /// earlier request can never fail a newer one.
    private var pendingID = 0
    private var nextRequestID = 0
    private var generation = 0

    private static let endMarker = Data("@@END\n".utf8)

    public init(server: ServerConfig) {
        self.server = server
    }

    deinit { close() }

    /// Bytes received over the lifetime of this session (for diagnostics).
    public private(set) var bytesReceived = 0

    public func fetch(timeout: TimeInterval = 20) async throws -> ServerSnapshot {
        do {
            return SnapshotParser.parse(try await request(timeout: timeout))
        } catch SSHError.sessionClosed {
            // The cached session died since the last poll; retry once fresh.
            close()
            return SnapshotParser.parse(try await request(timeout: timeout))
        }
    }

    public func close() {
        lock.lock()
        let p = process
        process = nil
        input = nil
        let cont = pending
        pending = nil
        generation += 1
        lock.unlock()
        cont?.resume(throwing: SSHError.sessionClosed)
        if let p, p.isRunning { p.terminate() }
    }

    // MARK: - Internals

    private func request(timeout: TimeInterval) async throws -> String {
        let (handle, gen) = try startIfNeeded()
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if pending != nil {
                lock.unlock()
                cont.resume(throwing: SSHError.failed(code: 0, message: String(appLocalized: "上一次请求尚未完成")))
                return
            }
            nextRequestID += 1
            let id = nextRequestID
            pending = cont
            pendingID = id
            buffer.removeAll(keepingCapacity: true)
            lock.unlock()

            do {
                try handle.write(contentsOf: Data("\n".utf8))
            } catch {
                fail(SSHError.sessionClosed, generation: gen)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillWaiting = self.pending != nil && self.pendingID == id && self.generation == gen
                self.lock.unlock()
                if stillWaiting {
                    self.fail(SSHError.timeout, generation: gen)
                    self.close()
                }
            }
        }
    }

    private func startIfNeeded() throws -> (FileHandle, Int) {
        lock.lock()
        defer { lock.unlock() }
        if let process, process.isRunning, let input { return (input, generation) }

        generation += 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = SSHRunner.baseArguments(for: server) + [
            // Keepalive: detect dead links in ~45 s and keep NAT/firewall
            // mappings alive while the panel is closed and polls are sparse.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "TCPKeepAlive=yes",
            // Own connection; never ride on (or get torn down with) a user's
            // ControlMaster from ~/.ssh/config.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            server.target, RemoteScript.loopCommand,
        ]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        errBuffer.removeAll()
        buffer.removeAll()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            self.receive(data, generation: gen)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            self.lock.lock()
            if self.generation == gen {
                self.errBuffer.append(data)
                if self.errBuffer.count > 8192 { self.errBuffer.removeFirst(self.errBuffer.count - 8192) }
            }
            self.lock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // Let the stderr handler drain before reporting.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                self.lock.lock()
                let err = String(decoding: self.errBuffer, as: UTF8.self)
                let current = self.generation == gen
                if current {
                    self.process = nil
                    self.input = nil
                }
                self.lock.unlock()
                guard current else { return }
                let message = SSHRunner.lastMeaningfulLine(err)
                self.fail(message.isEmpty && proc.terminationStatus == 0
                    ? SSHError.sessionClosed
                    : SSHError.failed(code: proc.terminationStatus, message: message), generation: gen)
            }
        }

        do {
            try p.run()
        } catch {
            throw SSHError.launch(error.localizedDescription)
        }
        process = p
        input = inPipe.fileHandleForWriting
        return (inPipe.fileHandleForWriting, gen)
    }

    private func receive(_ data: Data, generation gen: Int) {
        lock.lock()
        guard generation == gen else {
            lock.unlock()
            return
        }
        bytesReceived += data.count
        buffer.append(data)
        guard let range = buffer.range(of: Self.endMarker) else {
            lock.unlock()
            return
        }
        let chunk = buffer.subdata(in: buffer.startIndex..<range.upperBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        let cont = pending
        pending = nil
        lock.unlock()
        cont?.resume(returning: String(decoding: chunk, as: UTF8.self))
    }

    private func fail(_ error: Error, generation gen: Int) {
        lock.lock()
        guard generation == gen, let cont = pending else {
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        cont.resume(throwing: error)
    }
}
#endif
