import DeskhandCore
import NIOHTTP1
import Testing

@testable import DeskhandServer

@Suite struct RequestScreenTests {
    private static let screen = RequestScreen(ListenerHarness.configuration())

    struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        var method = HTTPMethod.POST
        var uri = "/mcp"
        var changes: [(String, String?)] = []
        let expected: HTTPRefusal?

        var testDescription: String { label }

        var head: HTTPRequestHead {
            var request = TestRequest.valid()
            for (name, value) in changes { request = request.setting(name, to: value) }
            return HTTPRequestHead(version: .http1_1, method: method, uri: uri, headers: HTTPHeaders(request.headers))
        }
    }

    private static let oversize = String(ContractConstants.maxRequestBodyBytes + 1)

    static let headCases: [Case] = [
        Case(label: "valid", expected: nil),
        Case(label: "query on /mcp", uri: "/mcp?x=1", expected: nil),
        Case(label: "wrong path beats wrong method", method: .GET, uri: "/other", expected: .notFound),
        Case(label: "trailing slash", uri: "/mcp/", expected: .notFound),
        Case(
            label: "wrong method beats bad Host", method: .GET, changes: [("Host", "x:1")], expected: .methodNotAllowed),
        Case(
            label: "bad Host beats Origin", changes: [("Host", "x:1"), ("Origin", "https://a")], expected: .misdirected),
        Case(
            label: "bare name when the service port is not 443", changes: [("Host", TestPKI.serverName)],
            expected: .misdirected),
        Case(
            label: "Host with trailing dot", changes: [("Host", TestPKI.serverName + ".:8443")], expected: .misdirected),
        Case(
            label: "Origin beats a missing token", changes: [("Origin", "null"), ("Authorization", nil)],
            expected: .originPresent),
        Case(label: "empty Origin", changes: [("Origin", "")], expected: .originPresent),
        Case(
            label: "missing token beats bad Content-Type", changes: [("Authorization", nil), ("Content-Type", nil)],
            expected: .unauthorized),
        Case(label: "lowercase scheme", changes: [("Authorization", "bearer \(ListenerHarness.token)")], expected: nil),
        Case(
            label: "two spaces after scheme", changes: [("Authorization", "Bearer  \(ListenerHarness.token)")],
            expected: nil),
        Case(
            label: "token with a trailing word", changes: [("Authorization", "Bearer \(ListenerHarness.token) x")],
            expected: .unauthorized),
        Case(label: "token prefix", changes: [("Authorization", "Bearer test-token")], expected: .unauthorized),
        Case(
            label: "bad Content-Type beats oversize body",
            changes: [("Content-Type", "text/plain"), ("Content-Length", oversize)], expected: .unsupportedMediaType),
        Case(label: "charset utf-8", changes: [("Content-Type", "application/json; charset=utf-8")], expected: nil),
        Case(
            label: "quoted upper-case charset", changes: [("Content-Type", #"Application/JSON;charset="UTF-8""#)],
            expected: nil),
        Case(
            label: "other charset", changes: [("Content-Type", "application/json; charset=latin1")],
            expected: .unsupportedMediaType),
        Case(
            label: "other parameter", changes: [("Content-Type", "application/json; v=1")],
            expected: .unsupportedMediaType),
        Case(label: "json-seq", changes: [("Content-Type", "application/json-seq")], expected: .unsupportedMediaType),
        Case(
            label: "declared oversize body beats a bad Accept",
            changes: [("Content-Length", oversize), ("Accept", "text/html")], expected: .bodyTooLarge),
    ]

    @Test(arguments: headCases)
    func headChecksRunInTableOrder(_ testCase: Case) {
        let result = Self.screen.screenHead(testCase.head, tokens: ListenerHarness.acceptedTokens, now: .now)
        switch result {
        case .success: #expect(testCase.expected == nil)
        case .failure(let refusal): #expect(refusal == testCase.expected)
        }
    }

    @Test func duplicateHostOrAuthorizationIsRefused() {
        var duplicateHost = TestRequest.valid()
        duplicateHost.headers.append(("Host", ListenerHarness.host))
        var duplicateToken = TestRequest.valid()
        duplicateToken.headers.append(("Authorization", "Bearer \(ListenerHarness.token)"))
        let heads = [duplicateHost, duplicateToken].map {
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp", headers: HTTPHeaders($0.headers))
        }
        let results = heads.map { Self.screen.screenHead($0, tokens: ListenerHarness.acceptedTokens, now: .now) }
        #expect(results.map(\.failure) == [.misdirected, .unauthorized])
    }

    @Test func noTokenIsAcceptedWhileTheTokenFileIsBroken() {
        let head = Case(label: "valid", expected: nil).head
        #expect(Self.screen.screenHead(head, tokens: .none, now: .now).failure == .unauthorized)
    }

    @Test(
        arguments: [
            (nil, true),
            ("application/json", true),
            ("application/json, text/event-stream", true),
            ("*/*", true),
            ("application/*", true),
            ("text/event-stream", false),
            ("application/json;q=0", false),
            ("text/html, application/json;q=0.5", true),
            ("text/html, */*;q=0", false),
        ] as [(String?, Bool)])
    func acceptMustAdmitJSON(_ accept: String?, _ admitted: Bool) throws {
        let head = Case(label: "accept", changes: [("Accept", accept)], expected: nil).head
        let screened = try Self.screen.screenHead(head, tokens: ListenerHarness.acceptedTokens, now: .now).get()
        #expect((Self.screen.screenAccept(screened) == nil) == admitted)
    }

    @Test func bodyLimitIsInclusive() {
        #expect(Self.screen.screenBody(byteCount: ContractConstants.maxRequestBodyBytes) == nil)
        #expect(Self.screen.screenBody(byteCount: ContractConstants.maxRequestBodyBytes + 1) == .bodyTooLarge)
    }

    @Test func refusalsCarryTheirStatusAndHeaders() {
        #expect(HTTPRefusal.allCases.map(\.status.code) == [431, 404, 405, 421, 403, 401, 415, 413, 406])
        #expect(HTTPRefusal.methodNotAllowed.headers.map(\.1) == ["POST"])
        #expect(HTTPRefusal.unauthorized.headers.map(\.1) == [#"Bearer realm="deskhand""#])
    }
}

@Suite struct HostAllowlistTests {
    @Test func servicePort443AlsoAcceptsTheBareName() {
        let hosts = HostAllowlist(names: ["deskhand-m1max2021.forge.svc"], servicePort: 443)
        #expect(hosts.accepts("deskhand-m1max2021.forge.svc"))
        #expect(hosts.accepts("DESKHAND-M1MAX2021.forge.svc:443"))
        #expect(!hosts.accepts("deskhand-m1max2021.forge.svc:8443"))
    }

    @Test(arguments: [
        "", "10.0.0.149:8443", "[::1]:8443", "desk\u{212A}hand.forge.svc:8443", "deskhand.forge.svc:08443",
    ])
    func lookalikesAreRefused(_ host: String) {
        let hosts = HostAllowlist(names: ["deskhand.forge.svc", "deskkhand.forge.svc"], servicePort: 8443)
        #expect(!hosts.accepts(host))
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
