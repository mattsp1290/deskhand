import DeskhandCore
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Synchronization
import Testing

@testable import DeskhandServer

/// A handler that holds each call until the test releases it.
private final class GatedHandler: RequestHandler {
    private let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let entered: AsyncStream<Void>.Continuation
    let calls: AsyncStream<Void>

    init() {
        (calls, entered) = AsyncStream.makeStream()
    }

    func handle(_ request: AuthenticatedRequest) async -> HandlerResponse {
        await withCheckedContinuation { continuation in
            gate.withLock { $0 = continuation }
            entered.yield()
        }
        return .json(request.body)
    }

    func release() { gate.withLock { $0.take() }?.resume() }
}

/// `CONNECTION_MAX_AGE` (contract 2.1) on the connection's own event loop, whose clock the test
/// advances, so the outcome does not depend on how fast the machine runs.
@Suite(.timeLimit(.minutes(1))) struct ConnectionMaxAgeTests {
    private let maxAge = ListenerHarness.configuration().connectionMaxAge

    private func connection(handler: any RequestHandler) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.testingEventLoop.executeInContext {
            let session = ConnectionSession()
            session.principal = Principal(certificateSubject: TestPKI.expectedSubject)
            try channel.pipeline.syncOperations.addHandler(
                ConnectionHandler(
                    configuration: ListenerHarness.configuration(),
                    session: session,
                    tokens: FixedTokenProvider(tokens: ListenerHarness.acceptedTokens),
                    handler: handler,
                    events: { _ in }
                ))
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        return channel
    }

    private func send(_ request: TestRequest, to channel: NIOAsyncTestingChannel) async throws {
        let head = HTTPRequestHead(
            version: .http1_1, method: request.method, uri: request.uri, headers: HTTPHeaders(request.headers))
        try await channel.writeInbound(HTTPServerRequestPart.head(head))
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(bytes: request.body)))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
    }

    /// The response head, after which the body and end are consumed.
    private func response(from channel: NIOAsyncTestingChannel) async throws -> HTTPResponseHead {
        guard case .head(let head) = try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self) else {
            throw ChannelError.inappropriateOperationForState
        }
        while case .body = try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self) {}
        return head
    }

    @Test func idleConnectionIsClosedAtTheMaxAge() async throws {
        let channel = try await connection(handler: RecordingHandler())
        try await send(.valid(), to: channel)
        let first = try await response(from: channel)
        #expect(first.status == .ok)
        #expect(first.headers["Connection"] == ["keep-alive"])

        await channel.testingEventLoop.advanceTime(by: maxAge - .nanoseconds(1))
        #expect(channel.isActive)
        await channel.testingEventLoop.advanceTime(by: .nanoseconds(1))
        #expect(!channel.isActive)
    }

    @Test func callInFlightAtTheMaxAgeCompletesThenTheConnectionCloses() async throws {
        let handler = GatedHandler()
        let channel = try await connection(handler: handler)
        try await send(.valid(), to: channel)
        var calls = handler.calls.makeAsyncIterator()
        _ = await calls.next()

        await channel.testingEventLoop.advanceTime(by: maxAge)
        #expect(channel.isActive)
        handler.release()
        let head = try await response(from: channel)
        #expect(head.status == .ok)
        #expect(head.headers["Connection"] == ["close"])
        await channel.testingEventLoop.advanceTime(by: ListenerHarness.configuration().closeLinger)
        #expect(!channel.isActive)
    }

    @Test func responseJustBeforeTheMaxAgeKeepsTheConnection() async throws {
        let handler = GatedHandler()
        let channel = try await connection(handler: handler)
        try await send(.valid(), to: channel)
        var calls = handler.calls.makeAsyncIterator()
        _ = await calls.next()

        await channel.testingEventLoop.advanceTime(by: maxAge - .nanoseconds(1))
        handler.release()
        #expect(try await response(from: channel).headers["Connection"] == ["keep-alive"])
        #expect(channel.isActive)
    }
}
