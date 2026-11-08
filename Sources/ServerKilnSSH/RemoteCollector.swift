import Foundation
import NIOCore
import ServerKilnCore

/// The iOS counterpart of `SSHSession`: one long-lived exec channel running
/// `RemoteScript.loop`, one newline per refresh, read until `@@END`.
///
/// With a monitoring key the server forces `collect.sh` regardless of the
/// command we send, so the key can never be used for anything else.
public final class RemoteCollector: @unchecked Sendable {
    public let endpoint: SSHEndpoint
    private let identity: SSHIdentity
    private let lock = NSLock()
    private var connection: SSHConnection?
    private var channel: Channel?
    private var sink: CollectorSink?

    public init(endpoint: SSHEndpoint, identity: SSHIdentity) {
        self.endpoint = endpoint
        self.identity = identity
    }

    deinit { close() }

    public func fetch(timeout: TimeInterval = 15) async throws -> ServerSnapshot {
        do {
            return SnapshotParser.parse(try await request(timeout: timeout))
        } catch SSHClientError.closed {
            // The cached channel died since the last poll; retry once fresh.
            close()
            return SnapshotParser.parse(try await request(timeout: timeout))
        }
    }

    public func close() {
        lock.lock()
        let c = connection, s = sink
        connection = nil
        channel = nil
        sink = nil
        lock.unlock()
        s?.fail(SSHClientError.closed)
        c?.close()
    }

    private func request(timeout: TimeInterval) async throws -> String {
        let (channel, sink) = try await startIfNeeded(timeout: timeout)
        return try await withCheckedThrowingContinuation { cont in
            guard let id = sink.begin(cont) else { return }
            var buffer = channel.allocator.buffer(capacity: 1)
            buffer.writeString("\n")
            channel.writeAndFlush(buffer).whenFailure { _ in sink.fail(SSHClientError.closed) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                // Only this request: a stale timer must never fail a newer one.
                if sink.fail(SSHClientError.timeout, requestID: id) { self?.close() }
            }
        }
    }

    private func startIfNeeded(timeout: TimeInterval) async throws -> (Channel, CollectorSink) {
        if let live = lock.withLock({ () -> (Channel, CollectorSink)? in
            guard let c = self.channel, c.isActive, let s = self.sink else { return nil }
            return (c, s)
        }) {
            return live
        }
        close()
        let conn = try await SSHConnection.connect(endpoint, identity: identity, timeout: timeout)
        let sink = CollectorSink()
        do {
            let channel = try await conn.openSession(command: RemoteScript.loopCommand, pty: nil, sink: sink, timeout: timeout)
            lock.withLock {
                self.connection = conn
                self.channel = channel
                self.sink = sink
            }
            return (channel, sink)
        } catch {
            conn.close()
            throw error
        }
    }
}

/// Accumulates channel output and completes the pending request at `@@END`.
private final class CollectorSink: SessionSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: CheckedContinuation<String, Error>?
    private var isClosed = false
    private var pendingID = 0
    private static let endMarker = Data("@@END\n".utf8)

    /// Registers a request and returns its ID; fails it immediately if one
    /// is already running.
    func begin(_ cont: CheckedContinuation<String, Error>) -> Int? {
        lock.lock()
        if isClosed {
            lock.unlock()
            cont.resume(throwing: SSHClientError.closed)
            return nil
        }
        if pending != nil {
            lock.unlock()
            cont.resume(throwing: SSHClientError.connect(String(appLocalized: "上一次请求尚未完成")))
            return nil
        }
        pending = cont
        pendingID += 1
        let id = pendingID
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        return id
    }

    func received(_ data: Data) {
        lock.lock()
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

    func closed() {
        lock.lock()
        isClosed = true
        lock.unlock()
        fail(SSHClientError.closed)
    }

    @discardableResult
    func fail(_ error: Error, requestID: Int? = nil) -> Bool {
        lock.lock()
        if let requestID, requestID != pendingID {
            lock.unlock()
            return false
        }
        let cont = pending
        pending = nil
        lock.unlock()
        cont?.resume(throwing: error)
        return cont != nil
    }
}
