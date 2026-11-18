import DeskhandCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Synchronization
import Testing

@testable import DeskhandServer

/// How a caller ends its side of the connection while its call runs.
enum CallerHalfClose: CaseIterable, Sendable {
    /// TLS close_notify, with the TCP stream left open.
    case closeNotify
    /// TLS close_notify, then end of stream.
    case closeNotifyThenEndOfStream
    /// End of stream with no close_notify.
    case endOfStream
}

/// A call that runs until it is cancelled. Its cancellation handler blocks the canceller for
/// ``recordDelay`` before it records the cancellation, so a close that deskhand sends before it
/// cancels reaches the client well before the record: the ordering check cannot pass by luck.
final class CancellationOrderHandler: RequestHandler {
    static let recordDelay: useconds_t = 150_000

    private let state = Mutex((started: false, cancelled: false))

    var started: Bool { state.withLock { $0.started } }
    var cancelled: Bool { state.withLock { $0.cancelled } }

    func handle(_ request: AuthenticatedRequest) async -> HandlerResponse {
        state.withLock { $0.started = true }
        await withTaskCancellationHandler {
            try? await Task.sleep(for: .seconds(50))
        } onCancel: {
            usleep(Self.recordDelay)
            state.withLock { $0.cancelled = true }
        }
        return .json([])
    }
}

/// What a ``HalfClosingClient`` saw of deskhand closing, each with whether the call had already
/// been cancelled at that moment.
struct Sightings: Sendable {
    /// deskhand's TLS close_notify.
    var closeNotify: Bool?
    /// deskhand's end of stream.
    var endOfStream: Bool?
    /// The stream ended without a close_notify before it.
    var ragged = false
    /// Application bytes deskhand sent.
    var response: [UInt8] = []
}

/// A TLS client that can end its side of the connection in each ``CallerHalfClose`` way and then
/// keeps the socket open to watch deskhand's close_notify and end of stream arrive separately.
struct HalfClosingClient {
    /// Not the listener's group: the handler's cancellation blocks the listener's event loop, and
    /// the client must go on reading meanwhile.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let channel: any Channel
    private let record: Recorder

    var sightings: Sightings { record.seen.withLock { $0 } }

    static func connect(
        to address: SocketAddress, pki: TestPKI, callCancelled: @escaping @Sendable () -> Bool
    ) async throws -> HalfClosingClient {
        let identity = pki.identity(.valid)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([pki.caCertificate])
        tls.minimumTLSVersion = .tlsv13
        tls.certificateChain = [.certificate(identity.certificate)]
        tls.privateKey = .privateKey(identity.key)
        let context = try NIOSSLContext(configuration: tls)
        let record = Recorder(callCancelled: callCancelled)
        let loop = group.next()
        let handshake = loop.makePromise(of: Void.self)
        let channel: any Channel
        do {
            channel = try await ClientBootstrap(group: loop)
                .channelOption(.allowRemoteHalfClosure, value: true)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        try pipeline.addHandler(SocketEnd(record))
                        try pipeline.addHandler(
                            try NIOSSLClientHandler(context: context, serverHostname: TestPKI.serverName))
                        try pipeline.addHandler(Watcher(record, handshake: handshake))
                    }
                }
                .connect(to: address).get()
        } catch {
            handshake.fail(error)
            throw error
        }
        try await handshake.futureResult.get()
        return HalfClosingClient(channel: channel, record: record)
    }

    func send(_ bytes: [UInt8]) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
    }

    func halfClose(_ halfClose: CallerHalfClose) async throws {
        let channel = self.channel
        try await channel.eventLoop.submit {
            let socket = try channel.pipeline.syncOperations.handler(type: SocketEnd.self)
            switch halfClose {
            case .closeNotify, .closeNotifyThenEndOfStream:
                // NIOSSL sends close_notify, then closes the socket's output unless SocketEnd holds it.
                socket.passesOutputClose = halfClose == .closeNotifyThenEndOfStream
                channel.close(mode: .output, promise: nil)
            case .endOfStream:
                let below = try channel.pipeline.syncOperations.context(handler: socket)
                below.close(mode: .output, promise: nil)
            }
        }.get()
    }

    /// Closes the socket for good.
    func release() async {
        let channel = self.channel
        try? await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.handler(type: SocketEnd.self).passesClose = true
            channel.close(promise: nil)
        }.get()
        try? await channel.closeFuture.get()
    }

    private final class Recorder: Sendable {
        let seen = Mutex(Sightings())
        let callCancelled: @Sendable () -> Bool

        init(callCancelled: @escaping @Sendable () -> Bool) { self.callCancelled = callCancelled }

        func closeNotify() {
            let cancelled = callCancelled()
            seen.withLock { if $0.closeNotify == nil, !$0.ragged { $0.closeNotify = cancelled } }
        }

        func endOfStream() {
            let cancelled = callCancelled()
            seen.withLock { if $0.endOfStream == nil { $0.endOfStream = cancelled } }
        }

        func ragged() { seen.withLock { if $0.closeNotify == nil { $0.ragged = true } } }

        func read(_ bytes: ByteBufferView) { seen.withLock { $0.response += bytes } }
    }

    /// The socket end of the pipeline, below TLS. It reports deskhand's end of stream and holds back
    /// the closes NIOSSL issues, so the socket stays open until deskhand ends the stream.
    private final class SocketEnd: ChannelDuplexHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundIn = ByteBuffer

        private let record: Recorder
        var passesOutputClose = false
        var passesClose = false
        private var failed = false

        init(_ record: Recorder) { self.record = record }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case .inputClosed? = event as? ChannelEvent { record.endOfStream() }
            context.fireUserInboundEventTriggered(event)
        }

        /// A read error (a reset) is not an end of stream.
        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            failed = true
            context.fireErrorCaught(error)
        }

        /// Once the client has closed its output, NIO reports deskhand's end of stream by closing.
        func channelInactive(context: ChannelHandlerContext) {
            if !failed, !passesClose { record.endOfStream() }
            context.fireChannelInactive()
        }

        func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            if passesClose || (mode == .output && passesOutputClose) {
                context.close(mode: mode, promise: promise)
            } else {
                promise?.succeed()
            }
        }
    }

    /// Above TLS. NIOSSL reports deskhand's close_notify as `shutdownCompleted` when the client has
    /// already sent its own, and as `inputClosed` when it has not. An end of stream without
    /// close_notify comes as `uncleanShutdown` first, then `inputClosed`.
    private final class Watcher: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        private let record: Recorder
        private let handshake: EventLoopPromise<Void>
        private var shookHands = false

        init(_ record: Recorder, handshake: EventLoopPromise<Void>) {
            self.record = record
            self.handshake = handshake
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            record.read(unwrapInboundIn(data).readableBytesView)
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case .handshakeCompleted = event as? TLSUserEvent, !shookHands {
                shookHands = true
                handshake.succeed()
            }
            if case .shutdownCompleted = event as? TLSUserEvent { record.closeNotify() }
            if case .inputClosed? = event as? ChannelEvent { record.closeNotify() }
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            if case .uncleanShutdown? = error as? NIOSSLError { record.ragged() }
        }

        func channelInactive(context: ChannelHandlerContext) {
            if !shookHands { handshake.fail(ChannelError.ioOnClosedChannel) }
            context.fireChannelInactive()
        }
    }
}

/// Contract 12.5: once a caller has ended its side of the connection, deskhand cancels the call
/// before it sends its own close_notify and before it ends the stream. Over a real socket, because
/// what matters is the order in which NIO, NIOSSL and the handler act on a real end of stream.
@Suite(.timeLimit(.minutes(1))) struct HalfCloseTests {
    private static func callInProgress(
        _ handler: CancellationOrderHandler, address: SocketAddress, pki: TestPKI
    ) async throws -> HalfClosingClient {
        let client = try await HalfClosingClient.connect(to: address, pki: pki) { handler.cancelled }
        try await client.send(TestRequest.valid().bytes)
        #expect(await eventually { handler.started })
        return client
    }

    @Test(arguments: CallerHalfClose.allCases)
    func theCallIsCancelledBeforeDeskhandCloses(_ halfClose: CallerHalfClose) async throws {
        let handler = CancellationOrderHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let client = try await Self.callInProgress(handler, address: address, pki: pki)
            let halfClosed = ContinuousClock.now
            try await client.halfClose(halfClose)

            #expect(await eventually { client.sightings.endOfStream != nil })
            // Well inside NIOSSL's 5 s shutdown timeout: deskhand does not wait for a close_notify
            // the caller has not sent.
            #expect(ContinuousClock.now - halfClosed < .seconds(4))
            let seen = client.sightings
            #expect(seen.closeNotify == true, "close_notify missing or sent before the call was cancelled")
            #expect(seen.endOfStream == true, "end of stream missing or sent before the call was cancelled")
            #expect(!seen.ragged)
            #expect(seen.response.isEmpty)
            await client.release()
        }
    }

    @Test func stoppingTheListenerCancelsTheCallBeforeCloseNotify() async throws {
        let pki = try TestPKI.get()
        let handler = CancellationOrderHandler()
        let listener = DeskhandListener(
            configuration: ListenerHarness.configuration(),
            tls: try ListenerHarness.makeTLS(pki),
            tokens: FixedTokenProvider(tokens: ListenerHarness.acceptedTokens),
            handler: handler
        )
        let address = try await listener.start()
        let client = try await Self.callInProgress(handler, address: address, pki: pki)

        // The listener's close waits for the client's close_notify, which this client never sends,
        // so the stop finishes once the client lets go of the socket.
        async let stopped: Void = listener.stop()
        #expect(await eventually { client.sightings.closeNotify != nil })
        #expect(client.sightings.closeNotify == true, "close_notify sent before the call was cancelled")
        await client.release()
        await stopped
    }
}
