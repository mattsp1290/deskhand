import DeskhandCore
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import DeskhandServer

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum HangUp: CaseIterable, Sendable {
    case reset
    case closeWithoutCloseNotify
    case halfClose
}

/// Sits at the socket end of a test client's pipeline. A close issued from here never passes the
/// TLS handler, so no close_notify is sent.
private final class BelowTLS: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
}

struct HangingUpClient {
    let channel: any Channel

    static func connect(to address: SocketAddress, pki: TestPKI) async throws -> HangingUpClient {
        let identity = pki.identity(.valid)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([pki.caCertificate])
        tls.minimumTLSVersion = .tlsv13
        tls.certificateChain = [.certificate(identity.certificate)]
        tls.privateKey = .privateKey(identity.key)
        let context = try NIOSSLContext(configuration: tls)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(BelowTLS())
                    try pipeline.addHandler(
                        try NIOSSLClientHandler(context: context, serverHostname: TestPKI.serverName))
                    try pipeline.addHTTPClientHandlers()
                }
            }
            .connect(to: address).get()
        return HangingUpClient(channel: channel)
    }

    func send(_ request: TestRequest) async throws {
        let head = HTTPRequestHead(
            version: .http1_1, method: request.method, uri: request.uri, headers: HTTPHeaders(request.headers))
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: request.body))), promise: nil)
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
    }

    func hangUp(_ hangUp: HangUp) async throws {
        if hangUp == .reset {
            let options = try #require(channel as? any SocketOptionProvider)
            try await options.setSoLinger(linger(l_onoff: 1, l_linger: 0)).get()
        }
        let channel = self.channel
        try await channel.eventLoop.submit {
            let belowTLS = try channel.pipeline.syncOperations.context(handlerType: BelowTLS.self)
            belowTLS.close(mode: hangUp == .halfClose ? .output : .all, promise: nil)
        }.get()
    }
}

@Suite(.timeLimit(.minutes(1))) struct HangUpTests {
    static let bound = Duration.seconds(5)

    @Test(arguments: HangUp.allCases)
    func hangUpWithoutCloseNotifyCancelsTheCall(_ hangUp: HangUp) async throws {
        let handler = RecordingHandler(delay: .seconds(50))
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let client = try await HangingUpClient.connect(to: address, pki: pki)
            try await client.send(.valid())
            #expect(await eventually { !handler.requests.isEmpty })

            let hungUp = ContinuousClock.now
            try await client.hangUp(hangUp)
            #expect(await eventually(timeout: Self.bound) { handler.cancellations == 1 })
            #expect(ContinuousClock.now - hungUp < Self.bound)
            try? await client.channel.close()
        }
    }

    @Test func acceptedConnectionsProbeAQuietPeer() async throws {
        let pki = try TestPKI.get()
        let configuration = ListenerHarness.configuration {
            $0.keepAliveIdle = .seconds(45)
            $0.keepAliveInterval = .seconds(7)
            $0.keepAliveProbes = 4
        }
        let listener = DeskhandListener(
            configuration: configuration,
            tls: try ListenerHarness.makeTLS(pki),
            tokens: FixedTokenProvider(tokens: ListenerHarness.acceptedTokens),
            handler: RecordingHandler()
        )
        let address = try await listener.start()
        try await TestClient.withConnection(to: address, pki: pki, as: .valid) { connection in
            #expect(await connection.roundTrip(.valid()).status == .ok)
            let accepted = try #require(listener.openConnections.first)
            #expect(try await accepted.getOption(.socketOption(.so_keepalive)).get() != 0)
            #if canImport(Darwin)
                let idle = NIOBSDSocket.Option(rawValue: TCP_KEEPALIVE)
            #else
                let idle = NIOBSDSocket.Option(rawValue: TCP_KEEPIDLE)
            #endif
            #expect(try await accepted.getOption(.tcpOption(idle)).get() == 45)
            #expect(try await accepted.getOption(.tcpOption(.init(rawValue: TCP_KEEPINTVL))).get() == 7)
            #expect(try await accepted.getOption(.tcpOption(.init(rawValue: TCP_KEEPCNT))).get() == 4)
        }
        await listener.stop()
    }
}

@Suite(.timeLimit(.minutes(1))) struct ConnectionCancellationTests {
    enum Ending: CaseIterable, Sendable {
        /// What NIOSSL reports for a FIN without close_notify.
        case uncleanShutdown
        case reset
        case parseError
        case inputClosed
        case closed
    }

    @Test(arguments: Ending.allCases)
    func everyEndingCancelsTheRunningCall(_ ending: Ending) async throws {
        let handler = RecordingHandler(delay: .seconds(50))
        let channel = try await EmbeddedConnection.make(handler: handler)
        try await EmbeddedConnection.send(.valid(), to: channel)
        #expect(await eventually { !handler.requests.isEmpty })

        switch ending {
        case .uncleanShutdown, .reset, .parseError:
            let error: any Error & Sendable =
                switch ending {
                case .uncleanShutdown: NIOSSLError.uncleanShutdown
                case .reset: IOError(errnoCode: ECONNRESET, reason: "read")
                default: HTTPParserError.invalidMethod
                }
            try await channel.testingEventLoop.executeInContext { channel.pipeline.fireErrorCaught(error) }
        case .inputClosed:
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }
        case .closed:
            try await channel.close()
        }
        #expect(await eventually(timeout: HangUpTests.bound) { handler.cancellations == 1 })
        #expect(!channel.isActive)
    }
}
