import DeskhandCore
import Foundation
import NIOCore
import Testing

@testable import DeskhandServer

/// Contract 2.2 accepts a client certificate only while it is in date. A resumed TLS 1.3 session
/// skips BoringSSL's certificate checks, so the listener must never resume one: a saved session is
/// worth nothing, with the certificate expired, absent or valid.
@Suite(.timeLimit(.minutes(1))) struct SessionResumptionTests {
    private static let request: [UInt8] = {
        let request = TestRequest.valid().setting("Connection", to: "close")
        var head = "POST \(request.uri) HTTP/1.1\r\n"
        for (name, value) in request.headers { head += "\(name): \(value)\r\n" }
        return Array((head + "\r\n").utf8) + request.body
    }()

    private static func client(_ pki: TestPKI, _ client: TestPKI.Client?) throws -> ResumingTLSClient {
        let identity = client.map(pki.identity)
        return try ResumingTLSClient(
            caPath: pki.caPath, certificatePath: identity?.certificatePath, keyPath: identity?.keyPath)
    }

    private static func exchange(
        _ client: ResumingTLSClient, _ address: SocketAddress, offering session: ResumingTLSClient.Session? = nil
    ) async throws -> ResumingTLSClient.Exchange {
        try await client.exchange(
            port: try #require(address.port), serverName: TestPKI.serverName, request: request, offering: session)
    }

    @Test func anIssuedSessionIsNeverResumed() async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let client = try Self.client(pki, .valid)
            let first = try await Self.exchange(client, address)
            #expect(first.status == 200)
            let session = try #require(first.issued, "without an issued session this test shows nothing")

            let second = try await Self.exchange(client, address, offering: session)
            #expect(!second.resumed)
            #expect(second.status == 200)
            #expect(handler.requests.count == 2)
        }
    }

    /// Reviewer repro: save a session, then offer it with no client certificate at all.
    @Test func aSavedSessionWithoutACertificateIsRefused() async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let first = try await Self.exchange(try Self.client(pki, .valid), address)
            let session = try #require(first.issued)

            let anonymous = try await Self.exchange(try Self.client(pki, nil), address, offering: session)
            #expect(!anonymous.resumed)
            #expect(anonymous.status == nil)
            #expect(handler.requests.count == 1)
        }
    }

    /// Reviewer repro: save a session while the certificate is valid, let it expire, offer the
    /// session. The listener's wall clock is moved past `notAfter`, since BoringSSL reads the real
    /// one; the date check the callback makes on every handshake refuses it.
    @Test func aSavedSessionDoesNotOutliveTheCertificate() async throws {
        let handler = RecordingHandler()
        let clock = ManualClock(ClockReading.now().wall)
        let wallClock: @Sendable () -> Timestamp = { clock.now }
        try await ListenerHarness.withListener(handler: handler, wallClock: wallClock) { address, pki, log in
            let client = try Self.client(pki, .valid)
            let first = try await Self.exchange(client, address)
            #expect(first.status == 200)
            let session = try #require(first.issued)

            let notAfter = Int64(pki.identity(.valid).certificate.notValidAfter)
            clock.set(Timestamp(millisecondsSinceEpoch: (notAfter + 1) * 1000))
            let resumed = try await Self.exchange(client, address, offering: session)
            #expect(!resumed.resumed)
            #expect(resumed.status == nil)
            let full = try await Self.exchange(client, address)
            #expect(full.status == nil)
            #expect(handler.requests.count == 1)
            #expect(log.refusals == [.expired, .expired])
        }
    }
}
