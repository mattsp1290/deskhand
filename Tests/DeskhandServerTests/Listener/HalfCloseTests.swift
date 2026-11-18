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

/// A call that runs until it is cancelled, after answering the first `answering` requests at once.
/// Its cancellation handler blocks the canceller for ``recordDelay`` before it records the
/// cancellation, so a close that deskhand sends before it cancels reaches the client well before
/// the record: a wrong order fails unless the client is stalled for longer than the delay.
final class CancellationOrderHandler: RequestHandler {
    static let recordDelay: useconds_t = 150_000

    private let answering: Int
    private let state = Mutex((received: 0, started: false, cancelled: false))

    init(answering: Int = 0) { self.answering = answering }

    var started: Bool { state.withLock { $0.started } }
    var cancelled: Bool { state.withLock { $0.cancelled } }

    func handle(_ request: AuthenticatedRequest) async -> HandlerResponse {
        let received = state.withLock {
            $0.received += 1
            return $0.received
        }
        guard received > answering else { return .json(request.body) }
        await withTaskCancellationHandler {
            // Set inside the handler's scope: once the test sees `started`, a cancellation runs
            // `onCancel` synchronously on the cancelling thread, the connection's event loop.
            state.withLock { $0.started = true }
            try? await Task.sleep(for: .seconds(50))
        } onCancel: {
            usleep(Self.recordDelay)
            state.withLock { $0.cancelled = true }
        }
        return .json([])
    }
}

/// One way deskhand's closing showed at a ``HalfClosingClient``, and whether the call had been
/// cancelled when it arrived.
struct Sighting: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// deskhand's TLS close_notify.
        case closeNotify
        /// deskhand's end of stream.
        case endOfStream
        /// NIOSSL saw the stream end with no close_notify before it.
        case ragged
    }

    let kind: Kind
    let cancelled: Bool
}

/// A TLS client that can end its side of the connection in each ``CallerHalfClose`` way and then
/// keeps the socket open to watch deskhand's close_notify and end of stream arrive separately.
struct HalfClosingClient {
    /// Not the listener's group: the handler's cancellation blocks the listener's event loop, and
    /// the client must go on reading meanwhile. Like NIO's singleton it lives as long as the test
    /// process and is never shut down.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let channel: any Channel
    private let record: Recorder

    /// What arrived, in arrival order, each kind once.
    var sightings: [Sighting] { record.state.withLock { $0.sightings } }
    /// Application bytes deskhand sent.
    var response: [UInt8] { record.state.withLock { $0.response } }

    static func connect(
        to address: SocketAddress, pki: TestPKI, callCancelled: @escaping @Sendable () -> Bool
    ) async throws -> HalfClosingClient {
        let context = try pki.clientContext()
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
        let state = Mutex((sightings: [Sighting](), response: [UInt8]()))
        let callCancelled: @Sendable () -> Bool

        init(callCancelled: @escaping @Sendable () -> Bool) { self.callCancelled = callCancelled }

        /// Keeps the first of each kind: NIO and NIOSSL can report the same ending twice.
        func saw(_ kind: Sighting.Kind) {
            let cancelled = callCancelled()
            state.withLock { state in
                guard !state.sightings.contains(where: { $0.kind == kind }) else { return }
                state.sightings.append(Sighting(kind: kind, cancelled: cancelled))
            }
        }

        func hasSeen(_ kind: Sighting.Kind) -> Bool { state.withLock { $0.sightings.contains { $0.kind == kind } } }

        func read(_ bytes: ByteBufferView) { state.withLock { $0.response += bytes } }
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
            if case .inputClosed? = event as? ChannelEvent { record.saw(.endOfStream) }
            context.fireUserInboundEventTriggered(event)
        }

        /// A read error (a reset) is not an end of stream.
        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            failed = true
            context.fireErrorCaught(error)
        }

        /// Once the client has closed its output, NIO reports deskhand's end of stream by closing.
        func channelInactive(context: ChannelHandlerContext) {
            if !failed, !passesClose { record.saw(.endOfStream) }
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
            // After a ragged end NIOSSL also reports `inputClosed`, which is no close_notify.
            if case .shutdownCompleted = event as? TLSUserEvent { record.saw(.closeNotify) }
            if case .inputClosed? = event as? ChannelEvent, !record.hasSeen(.ragged) { record.saw(.closeNotify) }
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            // NIOSSL also reports `uncleanShutdown` when the socket closes after deskhand's
            // close_notify; only an end with no close_notify before it is ragged.
            if case .uncleanShutdown? = error as? NIOSSLError, !record.hasSeen(.closeNotify) {
                record.saw(.ragged)
            }
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
    /// The listeners' own group, so the handler's blocking cancellation stalls no other suite. It
    /// lives as long as the test process.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    private static func connect(
        _ handler: CancellationOrderHandler, address: SocketAddress, pki: TestPKI
    ) async throws -> HalfClosingClient {
        try await HalfClosingClient.connect(to: address, pki: pki) { handler.cancelled }
    }

    private static func startCall(_ handler: CancellationOrderHandler, on client: HalfClosingClient) async throws {
        try await client.send(TestRequest.valid().bytes)
        try #require(await eventually { handler.started }, "the call never started")
    }

    /// deskhand's close_notify, then its end of stream, both after the cancellation, with no bytes
    /// beyond the first `response`, and well inside NIOSSL's 5 s shutdown timeout: deskhand does
    /// not wait for a close_notify the caller has not sent.
    private static func expectCancelledThenClosed(
        _ client: HalfClosingClient, since halfClosed: ContinuousClock.Instant, response: Int = 0
    ) async {
        #expect(await eventually { client.sightings.contains { $0.kind == .endOfStream } })
        #expect(ContinuousClock.now - halfClosed < .seconds(4))
        #expect(
            client.sightings == [
                Sighting(kind: .closeNotify, cancelled: true), Sighting(kind: .endOfStream, cancelled: true),
            ], "deskhand must send close_notify, then end the stream, both after the cancellation")
        #expect(client.response.count == response)
    }

    @Test(arguments: CallerHalfClose.allCases)
    func theCallIsCancelledBeforeDeskhandCloses(_ halfClose: CallerHalfClose) async throws {
        let handler = CancellationOrderHandler()
        try await ListenerHarness.withListener(handler: handler, group: Self.group) { address, pki, _ in
            let client = try await Self.connect(handler, address: address, pki: pki)
            try await Self.startCall(handler, on: client)
            let halfClosed = ContinuousClock.now
            try await client.halfClose(halfClose)
            await Self.expectCancelledThenClosed(client, since: halfClosed)
            await client.release()
        }
    }

    /// On a reused connection the earlier call's response arrives, then the close_notify, with
    /// nothing from the running call: the signal is per call, not per connection.
    @Test func aKeptAliveConnectionSignalsForTheRunningCall() async throws {
        let handler = CancellationOrderHandler(answering: 1)
        try await ListenerHarness.withListener(handler: handler, group: Self.group) { address, pki, _ in
            let client = try await Self.connect(handler, address: address, pki: pki)
            try await client.send(TestRequest.valid().bytes)
            try #require(await eventually { HTTPResponseBytes.isComplete(client.response) })
            let firstResponse = client.response.count
            #expect(firstResponse > 0)
            let head = String(decoding: client.response, as: UTF8.self).lowercased()
            #expect(head.contains("connection: keep-alive"), "the first response closed the connection")
            try await Self.startCall(handler, on: client)
            let halfClosed = ContinuousClock.now
            try await client.halfClose(.closeNotify)
            await Self.expectCancelledThenClosed(client, since: halfClosed, response: firstResponse)
            await client.release()
        }
    }

    /// A caller that ends its side partway through a request has hung up: deskhand answers nothing
    /// before its close_notify. The close_notify variants reach the decoder's end-of-input error
    /// (`invalidEOFState`); a plain end of stream closes through NIOSSL's `uncleanShutdown` first.
    @Test(arguments: CallerHalfClose.allCases)
    func endingMidRequestGetsNoResponse(_ halfClose: CallerHalfClose) async throws {
        let handler = CancellationOrderHandler()
        try await ListenerHarness.withListener(handler: handler, group: Self.group) { address, pki, _ in
            let client = try await Self.connect(handler, address: address, pki: pki)
            try await client.send(Array(TestRequest.valid().bytes.dropLast(5)))
            try await client.halfClose(halfClose)
            #expect(await eventually { client.sightings.contains { $0.kind == .endOfStream } })
            #expect(client.sightings.map(\.kind) == [.closeNotify, .endOfStream])
            #expect(client.response.isEmpty, "deskhand answered a request the caller abandoned")
            #expect(!handler.started)
            await client.release()
        }
    }

    @Test func stoppingTheListenerCancelsTheCallBeforeCloseNotify() async throws {
        let handler = CancellationOrderHandler()
        try await ListenerHarness.withRunningListener(handler: handler, group: Self.group) {
            listener, address, pki, _ in
            let client = try await Self.connect(handler, address: address, pki: pki)
            try await Self.startCall(handler, on: client)

            // The listener's close waits for the client's close_notify, which this client never
            // sends, so the stop finishes once the client lets go of the socket.
            async let stopped: Void = listener.stop()
            #expect(await eventually { client.sightings.contains { $0.kind == .closeNotify } })
            #expect(
                client.sightings.first == Sighting(kind: .closeNotify, cancelled: true),
                "close_notify sent before the call was cancelled")
            await client.release()
            await stopped
        }
    }
}

/// Just enough HTTP/1.1 response framing to tell when one response with a `Content-Length` body has
/// fully arrived. It handles only `Content-Length` framing, which is all deskhand sends, and
/// searches naively: test responses are a few hundred bytes.
enum HTTPResponseBytes {
    static func isComplete(_ bytes: [UInt8]) -> Bool {
        let separator: [UInt8] = Array("\r\n\r\n".utf8)
        guard let end = bytes.indices.first(where: { bytes[$0...].starts(with: separator) }) else { return false }
        let head = String(decoding: bytes[..<end], as: UTF8.self).lowercased()
        guard
            let line = head.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
            let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        else { return false }
        return bytes.count - (end + separator.count) >= length
    }
}
