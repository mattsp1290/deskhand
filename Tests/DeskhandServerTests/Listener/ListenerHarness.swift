import DeskhandCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Synchronization

@testable import DeskhandServer

struct FixedTokenProvider: TokenProvider {
    let tokens: AcceptedTokens

    func acceptedTokens() -> AcceptedTokens { tokens }
}

final class RecordingHandler: RequestHandler {
    private let delay: Duration?
    private let response: HandlerResponse?
    private let recorded = Mutex<[AuthenticatedRequest]>([])
    private let cancelled = Mutex(0)

    init(delay: Duration? = nil, response: HandlerResponse? = nil) {
        self.delay = delay
        self.response = response
    }

    var requests: [AuthenticatedRequest] { recorded.withLock { $0 } }
    var cancellations: Int { cancelled.withLock { $0 } }

    func handle(_ request: AuthenticatedRequest) async -> HandlerResponse {
        recorded.withLock { $0.append(request) }
        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                cancelled.withLock { $0 += 1 }
                return .json([])
            }
        }
        return response ?? .json(request.body)
    }
}

final class EventLog: Sendable {
    private let events = Mutex<[ListenerEvent]>([])

    func record(_ event: ListenerEvent) { events.withLock { $0.append(event) } }

    var all: [ListenerEvent] { events.withLock { $0 } }

    var refusals: [ClientCertificateRefusal] {
        all.compactMap {
            if case .clientCertificateRefused(let refusal) = $0 { return refusal }
            return nil
        }
    }
}

enum ListenerHarness {
    static let token = "test-token-not-a-secret"
    static let servicePort = 8443
    static let host = "\(TestPKI.serverName):\(servicePort)"

    static var acceptedTokens: AcceptedTokens { AcceptedTokens(current: BearerToken(secret: Array(token.utf8))) }

    static func configuration() -> ListenerConfiguration {
        var configuration = ListenerConfiguration(
            bindHost: "127.0.0.1",
            bindPort: 0,
            hosts: HostAllowlist(
                names: [TestPKI.serverName, "deskhand-test.forge.svc.cluster.local"],
                servicePort: servicePort
            ),
            clientCertificates: ClientCertificatePolicy(expectedSubject: TestPKI.expectedSubject)
        )
        // A refusal closes deskhand's output and lingers. A test client starved past the linger can
        // flush its request body after the full close; the reset that answers it makes NIO close
        // the client before it reads the refusal. Lingering past the suite's time limit leaves every
        // close to the client, so a loaded machine changes how long a test takes, not its outcome.
        configuration.closeLinger = .minutes(2)
        return configuration
    }

    static func makeTLS(_ pki: TestPKI) throws -> ServerTLSContextHolder {
        let credentials = try ServerTLSCredentials.load(
            caPath: pki.caPath,
            certificatePath: pki.serverCertificatePath,
            keyPath: pki.serverKeyPath
        )
        return ServerTLSContextHolder(try credentials.makeContext())
    }

    static func configuration(changing change: (inout ListenerConfiguration) -> Void) -> ListenerConfiguration {
        var changed = configuration()
        change(&changed)
        return changed
    }

    static func withListener(
        configuration: ListenerConfiguration = configuration(),
        handler: any RequestHandler = RecordingHandler(),
        wallClock: @escaping @Sendable () -> Timestamp = { ClockReading.now().wall },
        _ body: (SocketAddress, TestPKI, EventLog) async throws -> Void
    ) async throws {
        let pki = try TestPKI.get()
        let log = EventLog()
        let listener = DeskhandListener(
            configuration: configuration,
            tls: try makeTLS(pki),
            tokens: FixedTokenProvider(tokens: acceptedTokens),
            handler: handler,
            wallClock: wallClock,
            events: { log.record($0) }
        )
        let address = try await listener.start()
        do {
            try await body(address, pki, log)
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
    }
}

struct TestRequest {
    var method = HTTPMethod.POST
    var uri = "/mcp"
    var headers: [(String, String)]
    var body: [UInt8]

    static let toolsList = Array(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)

    static func valid(body: [UInt8] = toolsList) -> TestRequest {
        TestRequest(
            headers: [
                ("Host", ListenerHarness.host),
                ("Authorization", "Bearer \(ListenerHarness.token)"),
                ("Content-Type", "application/json"),
                ("Accept", "application/json, text/event-stream"),
                ("MCP-Protocol-Version", "2026-07-28"),
                ("Mcp-Method", "tools/list"),
                ("Content-Length", String(body.count)),
            ],
            body: body
        )
    }

    /// The request as HTTP/1.1 bytes, for a client that writes raw bytes.
    var bytes: [UInt8] {
        var head = "\(method.rawValue) \(uri) HTTP/1.1\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        return Array((head + "\r\n").utf8) + body
    }

    func setting(_ name: String, to value: String?) -> TestRequest {
        var copy = self
        copy.headers.removeAll { $0.0.lowercased() == name.lowercased() }
        if let value { copy.headers.append((name, value)) }
        return copy
    }
}

struct TestResponse {
    let status: HTTPResponseStatus
    let headers: HTTPHeaders
    let body: [UInt8]
}

enum Outcome {
    case response(TestResponse)
    case closed

    var response: TestResponse? {
        if case .response(let response) = self { return response }
        return nil
    }

    var status: HTTPResponseStatus? { response?.status }
}

struct TestConnection {
    fileprivate var inbound: NIOAsyncChannelInboundStream<HTTPClientResponsePart>.AsyncIterator
    fileprivate let outbound: NIOAsyncChannelOutboundWriter<HTTPClientRequestPart>

    func send(_ request: TestRequest) async -> Bool {
        let head = HTTPRequestHead(
            version: .http1_1,
            method: request.method,
            uri: request.uri,
            headers: HTTPHeaders(request.headers)
        )
        do {
            try await outbound.write(.head(head))
            if !request.body.isEmpty { try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: request.body)))) }
            try await outbound.write(.end(nil))
            return true
        } catch {
            return false
        }
    }

    mutating func next() async -> Outcome {
        var head: HTTPResponseHead?
        var body: [UInt8] = []
        do {
            while let part = try await inbound.next() {
                switch part {
                case .head(let received): head = received
                case .body(let buffer): body += buffer.readableBytesView
                case .end:
                    guard let head else { return .closed }
                    return .response(TestResponse(status: head.status, headers: head.headers, body: body))
                }
            }
        } catch {
            return .closed
        }
        return .closed
    }

    /// Reads the response even when the write fails: the listener deliberately answers some
    /// requests (a misdirected `Host`, an oversize `Content-Length`) before the body arrives and
    /// then closes, so the client's write can lose the race to that close.
    mutating func roundTrip(_ request: TestRequest) async -> Outcome {
        _ = await send(request)
        return await next()
    }
}

enum TestClient {
    static func withConnection<Result>(
        to address: SocketAddress,
        pki: TestPKI,
        as client: TestPKI.Client?,
        tlsVersion: TLSVersion = .tlsv13,
        _ body: (inout TestConnection) async throws -> Result
    ) async throws -> Result {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([pki.caCertificate])
        tls.certificateVerification = .fullVerification
        tls.minimumTLSVersion = tlsVersion
        tls.maximumTLSVersion = tlsVersion
        if let client {
            let identity = pki.identity(client)
            tls.certificateChain = [.certificate(identity.certificate)]
            tls.privateKey = .privateKey(identity.key)
        }
        let context = try NIOSSLContext(configuration: tls)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(to: address) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(
                        try NIOSSLClientHandler(context: context, serverHostname: TestPKI.serverName))
                    try pipeline.addHTTPClientHandlers()
                    return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(
                        wrappingChannelSynchronously: channel
                    )
                }
            }
        return try await channel.executeThenClose { inbound, outbound in
            var connection = TestConnection(inbound: inbound.makeAsyncIterator(), outbound: outbound)
            return try await body(&connection)
        }
    }

    static func roundTrip(
        _ request: TestRequest,
        to address: SocketAddress,
        pki: TestPKI,
        as client: TestPKI.Client? = .valid
    ) async throws -> Outcome {
        try await withConnection(to: address, pki: pki, as: client) { connection in
            await connection.roundTrip(request)
        }
    }
}
