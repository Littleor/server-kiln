import ServerKilnCore
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Where and as whom to connect, plus the host keys we trust. There is no
/// trust-on-first-use: a server presenting any other key is rejected.
public struct SSHEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    /// OpenSSH public key lines (`ssh-ed25519 AAAA…`), comments ignored.
    public var hostKeys: [String]

    public init(host: String, port: Int = 22, user: String, hostKeys: [String]) {
        self.host = host
        self.port = port
        self.user = user
        self.hostKeys = hostKeys
    }
}

public enum SSHClientError: Error, LocalizedError, Sendable, Equatable {
    case hostKeyMismatch(presented: String)
    case noPinnedHostKey
    case authenticationFailed
    case channelRejected
    case timeout
    case closed
    case connect(String)

    public var errorDescription: String? {
        switch self {
        case .hostKeyMismatch: return String(appLocalized: "主机密钥已变化，已拒绝连接")
        case .noPinnedHostKey: return String(appLocalized: "没有可信的主机密钥，请在 Mac 上重新部署")
        case .authenticationFailed: return String(appLocalized: "密钥认证失败，请在 Mac 上重新部署")
        case .channelRejected: return String(appLocalized: "服务器拒绝了请求")
        case .timeout: return String(appLocalized: "连接超时")
        case .closed: return String(appLocalized: "连接已断开")
        case let .connect(m): return m
        }
    }
}

public enum HostKey {
    /// `algorithm base64` of an OpenSSH public key line, without the comment.
    public static func normalize(_ line: String) -> String? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]) \(parts[1])"
    }

    /// Key types the iOS client can verify: Ed25519, ECDSA and RSA ≥ 2048
    /// (via rsa-sha2-*, see Vendor/patch-nio-ssh.py).
    public static func isSupported(_ line: String) -> Bool {
        guard let n = normalize(line), (try? NIOSSHPublicKey(openSSHPublicKey: n)) != nil else { return false }
        return true
    }

    /// SHA256 fingerprint as printed by `ssh-keygen -l`.
    public static func fingerprint(_ line: String) -> String? {
        guard let n = normalize(line), let blob = Data(base64Encoded: String(n.split(separator: " ")[1])) else { return nil }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// An Ed25519 identity in the formats the various parties need.
public struct SSHIdentity: Sendable {
    public let key: Curve25519.Signing.PrivateKey

    public init(key: Curve25519.Signing.PrivateKey = .init()) {
        self.key = key
    }

    public init(rawRepresentation: Data) throws {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { key.rawRepresentation }

    /// `ssh-ed25519 AAAA…` for `authorized_keys`.
    public var openSSHPublicKey: String {
        String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }
}

/// Shared event loops; one thread is plenty for a handful of sessions.
enum SSHEventLoop {
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

/// One authenticated SSH connection that can open session channels.
public final class SSHConnection: @unchecked Sendable {
    public let endpoint: SSHEndpoint
    private let channel: Channel
    private let failure: FailureBox

    private init(endpoint: SSHEndpoint, channel: Channel, failure: FailureBox) {
        self.endpoint = endpoint
        self.channel = channel
        self.failure = failure
    }

    public var isActive: Bool { channel.isActive }

    public static func connect(_ endpoint: SSHEndpoint, identity: SSHIdentity, timeout: TimeInterval = 10) async throws -> SSHConnection {
        let pinned = Set(endpoint.hostKeys.compactMap(HostKey.normalize))
        guard !pinned.isEmpty else { throw SSHClientError.noPinnedHostKey }
        let failure = FailureBox()
        let userAuth = KeyAuthDelegate(username: endpoint.user, key: NIOSSHPrivateKey(ed25519Key: identity.key), failure: failure)
        let hostAuth = PinnedHostKeyDelegate(pinned: pinned, failure: failure)

        let bootstrap = ClientBootstrap(group: SSHEventLoop.group)
            .connectTimeout(.milliseconds(Int64(timeout * 1000)))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: hostAuth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(ErrorCloser(failure: failure))
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            throw SSHClientError.connect(Self.describe(error))
        }
        return SSHConnection(endpoint: endpoint, channel: channel, failure: failure)
    }

    /// Opens a session channel. `pty` requests a terminal; `command == nil`
    /// starts the login shell. Waits for authentication and the server's
    /// acceptance before returning.
    func openSession(command: String?, pty: SSHChannelRequestEvent.PseudoTerminalRequest?, sink: SessionSink,
                     timeout: TimeInterval) async throws -> Channel {
        let ready = channel.eventLoop.makePromise(of: Void.self)
        let created = channel.eventLoop.makePromise(of: Channel.self)
        let handlerReady = ready
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case let .success(ssh):
                ssh.createChannel(created, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            SessionHandler(command: command, pty: pty, sink: sink, ready: handlerReady))
                    }
                }
            case let .failure(error):
                created.fail(error)
            }
        }
        created.futureResult.whenFailure { ready.fail($0) }
        let timer = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
            ready.fail(SSHClientError.timeout)
        }
        defer { timer.cancel() }
        do {
            try await ready.futureResult.get()
            return try await created.futureResult.get()
        } catch {
            if let known = failure.error { throw known }
            if let e = error as? SSHClientError { throw e }
            throw SSHClientError.connect(Self.describe(error))
        }
    }

    public func close() {
        channel.close(promise: nil)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? SSHClientError { return e.localizedDescription }
        if error is ChannelError { return String(appLocalized: "连接失败") }
        if let io = error as? IOError { return String(cString: strerror(io.errnoCode)) }
        if error is NIOConnectionError { return String(appLocalized: "无法连接到服务器") }
        return "\(error)"
    }
}

/// First error that explains why a connection failed.
final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: SSHClientError?

    var error: SSHClientError? { lock.withLock { _error } }

    func record(_ e: SSHClientError) {
        lock.withLock { if _error == nil { _error = e } }
    }
}

private final class ErrorCloser: ChannelInboundHandler {
    typealias InboundIn = Any
    let failure: FailureBox

    init(failure: FailureBox) { self.failure = failure }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class PinnedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let pinned: Set<String>
    let failure: FailureBox

    init(pinned: Set<String>, failure: FailureBox) {
        self.pinned = pinned
        self.failure = failure
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        if let n = HostKey.normalize(presented), pinned.contains(n) {
            validationCompletePromise.succeed(())
        } else {
            let e = SSHClientError.hostKeyMismatch(presented: presented)
            failure.record(e)
            validationCompletePromise.fail(e)
        }
    }
}

/// Offers the single Ed25519 key once; a rejection ends the attempt.
/// Only touched on the connection's event loop.
private final class KeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: NIOSSHPrivateKey
    let failure: FailureBox
    private var offered = false

    init(username: String, key: NIOSSHPrivateKey, failure: FailureBox) {
        self.username = username
        self.key = key
        self.failure = failure
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            failure.record(.authenticationFailed)
            nextChallengePromise.fail(SSHClientError.authenticationFailed)
            return
        }
        offered = true
        nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// Receives a session channel's output.
protocol SessionSink: AnyObject, Sendable {
    func received(_ data: Data)
    func closed()
}

/// Sends the pty / exec / shell requests and forwards stdout+stderr to the sink.
private final class SessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    let command: String?
    let pty: SSHChannelRequestEvent.PseudoTerminalRequest?
    let sink: SessionSink
    var ready: EventLoopPromise<Void>?
    /// Replies still expected before the session counts as started.
    private var pendingReplies = 0

    init(command: String?, pty: SSHChannelRequestEvent.PseudoTerminalRequest?, sink: SessionSink, ready: EventLoopPromise<Void>) {
        self.command = command
        self.pty = pty
        self.sink = sink
        self.ready = ready
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        if let pty {
            pendingReplies += 1
            context.triggerUserOutboundEvent(pty, promise: nil)
        }
        pendingReplies += 1
        if let command {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        } else {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            pendingReplies -= 1
            if pendingReplies == 0 {
                ready?.succeed(())
                ready = nil
            }
        case is ChannelFailureEvent:
            ready?.fail(SSHClientError.channelRejected)
            ready = nil
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let msg = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = msg.data else { return }
        sink.received(Data(buffer.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        ready?.fail(SSHClientError.closed)
        ready = nil
        sink.closed()
        context.fireChannelInactive()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// An interactive login shell on a pty, for the iPhone terminal.
public final class ShellSession: @unchecked Sendable {
    private let connection: SSHConnection
    private let channel: Channel
    private let sink: CallbackSink

    private init(connection: SSHConnection, channel: Channel, sink: CallbackSink) {
        self.connection = connection
        self.channel = channel
        self.sink = sink
    }

    /// `onData` and `onClose` are called on a background queue.
    public static func open(_ endpoint: SSHEndpoint, identity: SSHIdentity, columns: Int, rows: Int,
                            onData: @escaping @Sendable (Data) -> Void,
                            onClose: @escaping @Sendable () -> Void) async throws -> ShellSession {
        let conn = try await SSHConnection.connect(endpoint, identity: identity)
        let sink = CallbackSink(onData: onData, onClose: onClose)
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color", terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
        do {
            let channel = try await conn.openSession(command: nil, pty: pty, sink: sink, timeout: 15)
            return ShellSession(connection: conn, channel: channel, sink: sink)
        } catch {
            conn.close()
            throw error
        }
    }

    public var isActive: Bool { channel.isActive }

    public func send(_ data: Data) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func resize(columns: Int, rows: Int) {
        let event = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: columns, terminalRowHeight: rows,
                                                               terminalPixelWidth: 0, terminalPixelHeight: 0)
        channel.triggerUserOutboundEvent(event, promise: nil)
    }

    public func close() {
        channel.close(promise: nil)
        connection.close()
    }
}

private final class CallbackSink: SessionSink, @unchecked Sendable {
    let onData: @Sendable (Data) -> Void
    let onClose: @Sendable () -> Void

    init(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        self.onData = onData
        self.onClose = onClose
    }

    func received(_ data: Data) { onData(data) }
    func closed() { onClose() }
}

public extension SSHConnection {
    /// Runs one command and returns what it printed within `wait` seconds.
    /// With a monitor key the server substitutes its forced command.
    func run(_ command: String, wait: TimeInterval = 2) async throws -> String {
        let sink = BufferSink()
        let channel = try await openSession(command: command, pty: nil, sink: sink, timeout: 10)
        try await Task.sleep(for: .seconds(wait))
        channel.close(promise: nil)
        return sink.text
    }
}

private final class BufferSink: SessionSink, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    func received(_ d: Data) { lock.withLock { data.append(d) } }
    func closed() {}
}
