import DeskhandCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// What the listener reports for the log. Never carries a credential.
public enum ListenerEvent: Hashable, Sendable {
    case bound(SocketAddress)
    /// D14: the configured address is on no interface (EADDRNOTAVAIL); binding is retried.
    case bindUnavailable(retryIn: TimeAmount)
    case clientCertificateRefused(ClientCertificateRefusal)
    /// The handler produced a body over the response limit; the caller got `500` instead.
    case responseTooLarge(byteCount: Int)
}

public enum ListenerError: Error, Hashable, Sendable {
    /// ``DeskhandListener/stop()`` ran before the listener was bound.
    case stopped
}

/// The HTTPS endpoint of contract section 2: TLS 1.3 with mutual authentication against the
/// private CA, then checks 2 to 10 of the contract 2.4 table, then the ``RequestHandler``.
///
/// Each new connection takes the TLS configuration the ``ServerTLSContextHolder`` holds at accept
/// time, so a credential reload reaches new connections while open ones keep theirs.
///
/// No connection can resume a TLS session, so every handshake verifies the client certificate in
/// full. BoringSSL issues TLS 1.3 session tickets by default and does not check a resumed session's
/// certificate again, so a ticket would let a certificate keep authenticating for up to a week
/// after it expired, where contract 2.2 accepts it only while it is in date. NIOSSL has no switch
/// for tickets or the session cache, and both belong to the context, so each connection gets a
/// context of its own (``ServerTLSContextHolder/makeConnectionContext()``) whose tickets no other
/// connection can redeem. The verification callback also checks the leaf's dates against
/// `wallClock` on every handshake.
public final class DeskhandListener: Sendable {
    private struct State {
        var server: (any Channel)?
        var connections: [ObjectIdentifier: any Channel] = [:]
        var stopped = false
    }

    private let configuration: ListenerConfiguration
    private let tls: ServerTLSContextHolder
    private let tokens: any TokenProvider
    private let handler: any RequestHandler
    private let group: any EventLoopGroup
    private let wallClock: @Sendable () -> Timestamp
    private let events: @Sendable (ListenerEvent) -> Void
    private let state = Mutex(State())

    /// `wallClock` decides whether a client certificate is in date.
    public init(
        configuration: ListenerConfiguration,
        tls: ServerTLSContextHolder,
        tokens: any TokenProvider,
        handler: any RequestHandler,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        wallClock: @escaping @Sendable () -> Timestamp = { ClockReading.now().wall },
        events: @escaping @Sendable (ListenerEvent) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.tls = tls
        self.tokens = tokens
        self.handler = handler
        self.group = group
        self.wallClock = wallClock
        self.events = events
    }

    /// Binds and starts accepting, returning the bound address. While the address is on no
    /// interface it retries every ``ListenerConfiguration/bindRetryInterval`` and never gives up
    /// (D14); it stops retrying only when the calling task is cancelled or ``stop()`` runs. Any
    /// other bind failure is thrown. Call it once per listener.
    public func start() async throws -> SocketAddress {
        let address = try SocketAddress(ipAddress: configuration.bindHost, port: configuration.bindPort)
        let bootstrap = makeBootstrap()
        while true {
            try Task.checkCancellation()
            guard !state.withLock({ $0.stopped }) else { throw ListenerError.stopped }
            let server: any Channel
            do {
                server = try await bootstrap.bind(to: address).get()
            } catch let error as IOError where error.errnoCode == EADDRNOTAVAIL {
                events(.bindUnavailable(retryIn: configuration.bindRetryInterval))
                try await Task.sleep(nanoseconds: UInt64(max(0, configuration.bindRetryInterval.nanoseconds)))
                continue
            }
            let keep = state.withLock { state in
                guard !state.stopped else { return false }
                state.server = server
                return true
            }
            guard keep else {
                try? await server.close()
                throw ListenerError.stopped
            }
            let bound = server.localAddress ?? address
            events(.bound(bound))
            return bound
        }
    }

    /// Stops accepting and closes every open connection, which cancels any call in flight.
    public func stop() async {
        let (server, connections) = state.withLock { state in
            state.stopped = true
            defer {
                state.server = nil
                state.connections = [:]
            }
            return (state.server, Array(state.connections.values))
        }
        try? await server?.close()
        for connection in connections { try? await connection.close() }
    }

    var openConnections: [any Channel] { state.withLock { Array($0.connections.values) } }

    private func makeBootstrap() -> ServerBootstrap {
        ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(.socketOption(.so_keepalive), value: 1)
            .childChannelOption(.tcpOption(.keepAliveIdle), value: Self.seconds(configuration.keepAliveIdle))
            .childChannelOption(.tcpOption(.keepAliveInterval), value: Self.seconds(configuration.keepAliveInterval))
            .childChannelOption(.tcpOption(.keepAliveCount), value: Self.positive(configuration.keepAliveProbes))
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard track(channel) else { throw ListenerError.stopped }
                    try configurePipeline(channel)
                }
            }
    }

    private func track(_ channel: any Channel) -> Bool {
        let id = ObjectIdentifier(channel)
        let tracked = state.withLock { state in
            guard !state.stopped else { return false }
            state.connections[id] = channel
            return true
        }
        if tracked {
            channel.closeFuture.whenComplete { [self] _ in
                _ = state.withLock { $0.connections.removeValue(forKey: id) }
            }
        }
        return tracked
    }

    private static func seconds(_ amount: TimeAmount) -> SocketOptionValue {
        positive(amount.nanoseconds / 1_000_000_000)
    }

    private static func positive(_ value: some BinaryInteger) -> SocketOptionValue {
        SocketOptionValue(Int32(clamping: max(1, value)))
    }

    /// Runs on the new connection's event loop.
    private func configurePipeline(_ channel: any Channel) throws {
        let session = ConnectionSession()
        let policy = configuration.clientCertificates
        let wallClock = self.wallClock
        let events = self.events
        let context = try tls.makeConnectionContext()
        // NIOSSL calls this after BoringSSL has verified the chain on a full handshake, and also on
        // a resumed one, with the certificate stored in the session.
        let tlsHandler = NIOSSLServerHandler._makeSSLServerHandler(context: context) { certificate, channel in
            do {
                session.principal = try policy.authenticate(certificate, now: wallClock())
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch let refusal as ClientCertificateRefusal {
                events(.clientCertificateRefused(refusal))
                return channel.eventLoop.makeFailedFuture(refusal)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldSize = configuration.maxRequestHeaderBytes
        limits.maxHeaderListSize = configuration.maxRequestHeaderBytes
        let pipeline = channel.pipeline.syncOperations
        try pipeline.addHandler(tlsHandler)
        try pipeline.addHandler(
            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes, limitConfiguration: limits))
        )
        try pipeline.addHandler(HTTPResponseEncoder())
        try pipeline.addHandler(
            ConnectionHandler(
                configuration: configuration,
                session: session,
                tokens: tokens,
                handler: handler,
                events: events
            )
        )
    }
}

extension NIOBSDSocket.Option {
    #if canImport(Darwin)
        fileprivate static let keepAliveIdle = NIOBSDSocket.Option(rawValue: TCP_KEEPALIVE)
    #else
        fileprivate static let keepAliveIdle = NIOBSDSocket.Option(rawValue: TCP_KEEPIDLE)
    #endif
    fileprivate static let keepAliveInterval = NIOBSDSocket.Option(rawValue: TCP_KEEPINTVL)
    fileprivate static let keepAliveCount = NIOBSDSocket.Option(rawValue: TCP_KEEPCNT)
}
