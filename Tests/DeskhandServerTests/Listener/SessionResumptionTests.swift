import DeskhandCore
import Foundation
import NIOCore
import Testing

@testable import DeskhandServer

/// Contract 2.2 accepts a client certificate only while it is in date. A resumed TLS 1.3 session
/// skips BoringSSL's certificate checks, so the listener must never resume one: a saved session is
/// worth nothing, with the certificate expired, absent or valid.
@Suite(
    .timeLimit(.minutes(1)),
    .enabled(if: OpenSSLTool.resumptionTestsEnabled, Comment(rawValue: OpenSSLTool.resumptionRequirement))
)
struct SessionResumptionTests {
    private static let request: [UInt8] = {
        let request = TestRequest.valid().setting("Connection", to: "close")
        var head = "POST \(request.uri) HTTP/1.1\r\n"
        for (name, value) in request.headers { head += "\(name): \(value)\r\n" }
        return Array((head + "\r\n").utf8) + request.body
    }()

    private static func client(_ pki: TestPKI, _ client: TestPKI.Client?) -> OpenSSLSessionClient {
        OpenSSLSessionClient(pki: pki, client: client)
    }

    private static func exchange(
        _ client: OpenSSLSessionClient, _ address: SocketAddress, offering session: URL? = nil
    ) async throws -> OpenSSLSessionClient.Exchange {
        try await client.exchange(port: try #require(address.port), request: request, offering: session)
    }

    /// Without this, a client that cannot resume at all (LibreSSL's `s_client` among them) would pass
    /// every test below.
    @Test func theClientResumesWhereAServerAllowsIt() async throws {
        let pki = try TestPKI.get()
        try await ResumingTestServer.withServer(pki: pki) { server in
            let client = Self.client(pki, .valid)
            let first = try await client.exchange(port: server.port, request: Self.request)
            #expect(first.status == 200, Comment(rawValue: OpenSSLTool.resumptionRequirement))
            let session = try #require(first.issued, "s_client saved no session")
            let second = try await client.exchange(port: server.port, request: Self.request, offering: session)
            #expect(second.resumed, Comment(rawValue: OpenSSLTool.resumptionRequirement))
            #expect(second.status == 200)
        }
    }

    @Test func anIssuedSessionIsNeverResumed() async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let client = Self.client(pki, .valid)
            let first = try await Self.exchange(client, address)
            #expect(first.status == 200)
            let session = try #require(first.issued, "without an issued session this test shows nothing")

            let second = try await Self.exchange(client, address, offering: session)
            #expect(!second.resumed)
            #expect(second.status == 200)
            #expect(handler.requests.count == 2)
        }
    }

    @Test func aSavedSessionWithoutACertificateIsRefused() async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let first = try await Self.exchange(Self.client(pki, .valid), address)
            let session = try #require(first.issued)

            let anonymous = try await Self.exchange(Self.client(pki, nil), address, offering: session)
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
        // The certificates are generated on first use; the frozen clock must not predate them.
        _ = try TestPKI.get()
        let clock = ManualClock(ClockReading.now().wall)
        let wallClock: @Sendable () -> Timestamp = { clock.now }
        try await ListenerHarness.withListener(handler: handler, wallClock: wallClock) { address, pki, log in
            let client = Self.client(pki, .valid)
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
