import DeskhandCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import DeskhandServer

/// Real TLS over loopback against throwaway certificates from ``TestPKI``.
@Suite(.timeLimit(.minutes(1))) struct ListenerTLSTests {
    @Test func validClientReachesHandlerWithPrincipalBodyAndMCPHeaders() async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let outcome = try await TestClient.roundTrip(.valid(), to: address, pki: pki)
            let response = try #require(outcome.response)
            #expect(response.status == .ok)
            #expect(response.body == TestRequest.toolsList)
            #expect(response.headers["Content-Type"] == ["application/json"])
            #expect(response.headers["Access-Control-Allow-Origin"].isEmpty)
            let request = try #require(handler.requests.first)
            #expect(request.principal == Principal(certificateSubject: TestPKI.expectedSubject))
            #expect(request.body == TestRequest.toolsList)
            #expect(request.headers.protocolVersion == ["2026-07-28"])
            #expect(request.headers.method == ["tools/list"])
            #expect(request.headers.name.isEmpty)
        }
    }

    @Test(arguments: [TestPKI.Client.wrongCA, .serverAuthOnly, .noExtendedKeyUsage, .wrongSubject])
    func refusedClientCertificateFailsTheHandshake(_ client: TestPKI.Client) async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, log in
            let outcome = try await TestClient.roundTrip(.valid(), to: address, pki: pki, as: client)
            #expect(outcome.response == nil)
            #expect(handler.requests.isEmpty)
            switch client {
            case .noExtendedKeyUsage: #expect(log.refusals == [.missingClientAuthUsage])
            case .wrongSubject: #expect(log.refusals == [.unexpectedSubject("CN=someone-else,O=forge")])
            default: #expect(log.refusals.isEmpty, "BoringSSL refuses these before the D11 checks run")
            }
        }
    }

    @Test func missingClientCertificateFailsTheHandshake() async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let outcome = try await TestClient.roundTrip(.valid(), to: address, pki: pki, as: nil)
            #expect(outcome.response == nil)
            #expect(handler.requests.isEmpty)
        }
    }

    @Test func tls12IsRefused() async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let outcome = try await TestClient.withConnection(to: address, pki: pki, as: .valid, tlsVersion: .tlsv12) {
                await $0.roundTrip(.valid())
            }
            #expect(outcome.response == nil)
            #expect(handler.requests.isEmpty)
        }
    }

    @Test func originHeaderIsForbidden() async throws {
        try await ListenerHarness.withListener { address, pki, _ in
            let request = TestRequest.valid().setting("Origin", to: "https://example.invalid")
            let outcome = try await TestClient.roundTrip(request, to: address, pki: pki)
            #expect(outcome.status == .forbidden)
            #expect(outcome.response?.body.isEmpty == true)
        }
    }

    @Test(arguments: ["127.0.0.1:8443", "deskhand-test.forge.svc:443", "deskhand-other.forge.svc:8443", nil])
    func unacceptedHostIsMisdirected(_ host: String?) async throws {
        try await ListenerHarness.withListener { address, pki, _ in
            let request = TestRequest.valid().setting("Host", to: host)
            let outcome = try await TestClient.roundTrip(request, to: address, pki: pki)
            #expect(outcome.status == .misdirectedRequest)
        }
    }

    @Test func clusterLocalHostIsAcceptedCaseInsensitively() async throws {
        try await ListenerHarness.withListener { address, pki, _ in
            let request = TestRequest.valid().setting("Host", to: "Deskhand-Test.Forge.Svc.Cluster.Local:8443")
            let outcome = try await TestClient.roundTrip(request, to: address, pki: pki)
            #expect(outcome.status == .ok)
        }
    }

    @Test(arguments: [nil, "Bearer wrong-token", "Basic dGVzdA==", "Bearer"])
    func badOrMissingTokenIsUnauthorized(_ authorization: String?) async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let request = TestRequest.valid().setting("Authorization", to: authorization)
            let response = try #require(try await TestClient.roundTrip(request, to: address, pki: pki).response)
            #expect(response.status == .unauthorized)
            #expect(response.headers["WWW-Authenticate"] == [#"Bearer realm="deskhand""#])
            #expect(response.body.isEmpty)
            #expect(handler.requests.isEmpty)
        }
    }

    @Test func declaredOversizeBodyIsRefusedBeforeItArrives() async throws {
        try await ListenerHarness.withListener { address, pki, _ in
            let body = [UInt8](repeating: UInt8(ascii: " "), count: ContractConstants.maxRequestBodyBytes + 1)
            let outcome = try await TestClient.roundTrip(.valid(body: body), to: address, pki: pki)
            #expect(outcome.status == .payloadTooLarge)
        }
    }

    @Test func chunkedOversizeBodyIsRefused() async throws {
        try await ListenerHarness.withListener { address, pki, _ in
            let body = [UInt8](repeating: UInt8(ascii: " "), count: ContractConstants.maxRequestBodyBytes + 1)
            let request = TestRequest.valid(body: body).setting("Content-Length", to: nil)
            let outcome = try await TestClient.roundTrip(request, to: address, pki: pki)
            #expect(outcome.status == .payloadTooLarge)
        }
    }

    @Test func bodyAtTheLimitIsAccepted() async throws {
        try await ListenerHarness.withListener { address, pki, _ in
            let body = [UInt8](repeating: UInt8(ascii: " "), count: ContractConstants.maxRequestBodyBytes)
            let outcome = try await TestClient.roundTrip(.valid(body: body), to: address, pki: pki)
            #expect(outcome.status == .ok)
        }
    }

    @Test func oversizeHeaderBlockGets431() async throws {
        try await ListenerHarness.withListener { address, pki, _ in
            let filler = String(repeating: "a", count: ContractConstants.maxRequestHeaderBytes)
            let request = TestRequest.valid().setting("X-Filler", to: filler)
            let outcome = try await TestClient.roundTrip(request, to: address, pki: pki)
            #expect(outcome.status == .requestHeaderFieldsTooLarge)
        }
    }

    @Test func wrongPathAndMethodFollowTheTableOrder() async throws {
        try await ListenerHarness.withListener { address, pki, _ in
            var wrongPath = TestRequest.valid()
            wrongPath.uri = "/other"
            wrongPath.method = .GET
            #expect(try await TestClient.roundTrip(wrongPath, to: address, pki: pki).status == .notFound)
            var wrongMethod = TestRequest.valid()
            wrongMethod.method = .PUT
            let response = try #require(try await TestClient.roundTrip(wrongMethod, to: address, pki: pki).response)
            #expect(response.status == .methodNotAllowed)
            #expect(response.headers["Allow"] == ["POST"])
        }
    }

    @Test func keepAliveServesSeveralRequestsOnOneConnection() async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let statuses = try await TestClient.withConnection(to: address, pki: pki, as: .valid) { connection in
                [await connection.roundTrip(.valid()).status, await connection.roundTrip(.valid()).status]
            }
            #expect(statuses == [.ok, .ok])
            #expect(handler.requests.count == 2)
        }
    }

    @Test func disconnectCancelsTheHandlerTask() async throws {
        let handler = RecordingHandler(delay: .seconds(30))
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            try await TestClient.withConnection(to: address, pki: pki, as: .valid) { connection in
                #expect(await connection.send(.valid()))
                try await eventually { !handler.requests.isEmpty }
            }
            try await eventually { handler.cancellations > 0 }
            #expect(handler.requests.count == 1)
            #expect(handler.cancellations == 1)
        }
    }

    @Test func oversizeResponseIsNeverSent() async throws {
        let handler = RecordingHandler(response: .json([UInt8](repeating: 0x20, count: 2048)))
        let configuration = ListenerHarness.configuration { $0.maxResponseBodyBytes = 1024 }
        try await ListenerHarness.withListener(configuration: configuration, handler: handler) { address, pki, log in
            let response = try #require(try await TestClient.roundTrip(.valid(), to: address, pki: pki).response)
            #expect(response.status == .internalServerError)
            #expect(response.body.isEmpty)
            #expect(log.all.contains(.responseTooLarge(byteCount: 2048)))
        }
    }

    @Test func peerThatNeverHandshakesIsDisconnected() async throws {
        let configuration = ListenerHarness.configuration { $0.handshakeTimeout = .milliseconds(200) }
        try await ListenerHarness.withListener(configuration: configuration) { address, _, _ in
            let connecting = ContinuousClock.now
            let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(to: address)
                .get()
            try? await channel.closeFuture.get()
            #expect(ContinuousClock.now - connecting >= .milliseconds(200))
        }
    }

    @Test func bindRetriesWhileTheAddressIsUnavailable() async throws {
        let pki = try TestPKI.get()
        var configuration = ListenerHarness.configuration()
        // TEST-NET-1 (RFC 5737) is on no interface, so bind fails with EADDRNOTAVAIL.
        configuration.bindHost = "192.0.2.1"
        configuration.bindRetryInterval = .milliseconds(20)
        let log = EventLog()
        let listener = DeskhandListener(
            configuration: configuration,
            tls: try ListenerHarness.makeTLS(pki),
            tokens: FixedTokenProvider(tokens: ListenerHarness.acceptedTokens),
            handler: RecordingHandler(),
            events: { log.record($0) }
        )
        let start = Task { try await listener.start() }
        try await eventually { log.all.count >= 3 }
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(log.all.count >= 3)
        #expect(log.all.allSatisfy { $0 == .bindUnavailable(retryIn: .milliseconds(20)) })
    }

    @Test func newConnectionsUseAReplacedContext() async throws {
        let pki = try TestPKI.get()
        let holder = try ListenerHarness.makeTLS(pki)
        let listener = DeskhandListener(
            configuration: ListenerHarness.configuration(),
            tls: holder,
            tokens: FixedTokenProvider(tokens: ListenerHarness.acceptedTokens),
            handler: RecordingHandler()
        )
        let address = try await listener.start()
        #expect(try await TestClient.roundTrip(.valid(), to: address, pki: pki).status == .ok)
        // A context whose only trust root is the unrelated CA refuses the valid client.
        let refusing = try ServerTLSCredentials(
            caPEM: Array(try Data(contentsOf: pki.directory.appendingPathComponent("other-ca.pem"))),
            certificatePEM: Array(try Data(contentsOf: URL(fileURLWithPath: pki.serverCertificatePath))),
            keyPEM: Array(try Data(contentsOf: URL(fileURLWithPath: pki.serverKeyPath)))
        )
        holder.replace(with: try refusing.makeContext())
        #expect(try await TestClient.roundTrip(.valid(), to: address, pki: pki).response == nil)
        await listener.stop()
    }
}

/// Polls until `condition` holds. The suite's time limit bounds the wait, so a slow machine only
/// makes the test slower, never wrong.
private func eventually(_ condition: () -> Bool) async throws {
    while !condition() { try await Task.sleep(for: .milliseconds(10)) }
}
