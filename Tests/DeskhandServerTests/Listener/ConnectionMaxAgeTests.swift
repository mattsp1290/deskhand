import DeskhandCore
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Synchronization
import Testing

@testable import DeskhandServer

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

enum EmbeddedConnection {
    static func make(
        handler: any RequestHandler,
        configuration: ListenerConfiguration = ListenerHarness.configuration()
    ) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.testingEventLoop.executeInContext {
            let session = ConnectionSession()
            session.principal = Principal(certificateSubject: TestPKI.expectedSubject)
            try channel.pipeline.syncOperations.addHandler(
                ConnectionHandler(
                    configuration: configuration,
                    session: session,
                    tokens: FixedTokenProvider(tokens: ListenerHarness.acceptedTokens),
                    handler: handler,
                    events: { _ in }
                ))
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        return channel
    }

    static func sendHead(_ request: TestRequest, to channel: NIOAsyncTestingChannel) async throws {
        let head = HTTPRequestHead(
            version: .http1_1, method: request.method, uri: request.uri, headers: HTTPHeaders(request.headers))
        try await channel.writeInbound(HTTPServerRequestPart.head(head))
    }

    static func send(_ request: TestRequest, to channel: NIOAsyncTestingChannel) async throws {
        try await sendHead(request, to: channel)
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(bytes: request.body)))
        try await channel.writeInbound(HTTPServerRequestPart.end(nil))
    }

    static func response(from channel: NIOAsyncTestingChannel) async throws -> HTTPResponseHead {
        guard case .head(let head) = try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self) else {
            throw ChannelError.inappropriateOperationForState
        }
        while case .body = try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self) {}
        return head
    }
}

@Suite(.timeLimit(.minutes(1))) struct ConnectionMaxAgeTests {
    private let maxAge = ListenerHarness.configuration().connectionMaxAge
    private let bodyTimeout = ListenerHarness.configuration().requestBodyTimeout

    private func connection(
        handler: any RequestHandler,
        configuration: ListenerConfiguration = ListenerHarness.configuration()
    ) async throws -> NIOAsyncTestingChannel {
        try await EmbeddedConnection.make(handler: handler, configuration: configuration)
    }

    private func send(_ request: TestRequest, to channel: NIOAsyncTestingChannel) async throws {
        try await EmbeddedConnection.send(request, to: channel)
    }

    private func response(from channel: NIOAsyncTestingChannel) async throws -> HTTPResponseHead {
        try await EmbeddedConnection.response(from: channel)
    }

    private func sendStalledRequest(to channel: NIOAsyncTestingChannel) async throws {
        try await EmbeddedConnection.sendHead(.valid(), to: channel)
        try await channel.writeInbound(HTTPServerRequestPart.body(ByteBuffer(bytes: [0x7B])))
    }

    @Test func stalledBodyIsClosedAtTheBodyDeadline() async throws {
        let handler = RecordingHandler()
        let channel = try await connection(handler: handler)
        try await sendStalledRequest(to: channel)

        await channel.testingEventLoop.advanceTime(by: bodyTimeout - .nanoseconds(1))
        #expect(channel.isActive)
        await channel.testingEventLoop.advanceTime(by: .nanoseconds(1))
        #expect(!channel.isActive)
        #expect(handler.requests.isEmpty)
    }

    @Test func stalledBodyIsClosedAtTheMaxAge() async throws {
        let handler = RecordingHandler()
        let configuration = ListenerHarness.configuration { $0.requestBodyTimeout = .hours(24) }
        let channel = try await connection(handler: handler, configuration: configuration)
        try await sendStalledRequest(to: channel)

        await channel.testingEventLoop.advanceTime(by: maxAge - .nanoseconds(1))
        #expect(channel.isActive)
        await channel.testingEventLoop.advanceTime(by: .nanoseconds(1))
        #expect(!channel.isActive)
        #expect(handler.requests.isEmpty)
    }

    @Test func theBodyDeadlineEndsWithTheBody() async throws {
        let channel = try await connection(handler: RecordingHandler())
        try await send(.valid(), to: channel)
        #expect(try await response(from: channel).headers["Connection"] == ["keep-alive"])

        await channel.testingEventLoop.advanceTime(by: bodyTimeout)
        #expect(channel.isActive)
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
