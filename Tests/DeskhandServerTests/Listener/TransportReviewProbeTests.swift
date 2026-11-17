import DeskhandCore
import Testing

@testable import DeskhandServer

@Suite(.timeLimit(.minutes(1))) struct TransportReviewProbeTests {
    @Test func oversizedWhitespaceHeader() async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let client = try RawTLSClient(pki: pki)
            let request = TestRequest.valid().setting("Connection", to: "close")
            var head = "POST /mcp HTTP/1.1\r\n"
            for (name, value) in request.headers { head += "\(name): \(value)\r\n" }
            head += "X-Padding:" + String(repeating: " ", count: 20000) + "value\r\n\r\n"
            let response = try await client.exchange(to: address, request: Array(head.utf8) + request.body)
            print(
                "TRANSPORT_REVIEW headerBytes=\(head.utf8.count) limit=\(ContractConstants.maxRequestHeaderBytes) status=\(String(describing: response.status)) dispatched=\(handler.requests.count)"
            )
            #expect(response.status == 431)
            #expect(handler.requests.isEmpty)
        }
    }
}

extension TransportReviewProbeTests {
    @Test(arguments: 0..<7)
    func rawBoundariesAndPriority(_ scenario: Int) async throws {
        let handler = RecordingHandler()
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let client = try RawTLSClient(pki: pki)
            let body =
                scenario == 6
                ? Array(String(repeating: "POST /fake HTTP/1.1\r\n\r\n", count: 1000).utf8) : TestRequest.toolsList
            var request = TestRequest.valid(body: body).setting("Connection", to: "close")
            if scenario == 3 { request = request.setting("Authorization", to: nil) }
            var head = "POST \(scenario == 2 ? "/wrong" : "/mcp") HTTP/1.1\r\n"
            for (name, value) in request.headers { head += "\(name): \(value)\r\n" }
            head += "X-Padding:"
            let tooLarge = (1...4).contains(scenario)
            head += String(repeating: " ", count: 16_384 - head.utf8.count - 5 + (tooLarge ? 1 : 0))
            head += scenario == 4 ? String(repeating: " ", count: 100) : "x\r\n\r\n"
            let response = try await client.exchange(
                to: address, request: Array(head.utf8) + (scenario == 4 ? [] : body),
                fragmentSize: [1, 5].contains(scenario) ? 17 : nil)
            #expect(response.status == (tooLarge ? 431 : 200))
            #expect(handler.requests.count == (tooLarge ? 0 : 1))
            if !tooLarge { #expect(handler.requests.first?.body == body) }
        }
    }
}

extension TransportReviewProbeTests {
    @Test(arguments: [false, true])
    func coalescedBodyAndNextHead(_ oversized: Bool) async throws {
        let handler = RecordingHandler(delay: .milliseconds(100))
        try await ListenerHarness.withListener(handler: handler) { address, pki, _ in
            let client = try RawTLSClient(pki: pki)
            let request = TestRequest.valid()
            var head = "POST /mcp HTTP/1.1\r\n"
            for (name, value) in request.headers { head += "\(name): \(value)\r\n" }
            let first = Array((head + "\r\n").utf8) + request.body
            let second = head + "X-Padding:" + String(repeating: " ", count: oversized ? 20_000 : 10) + "x\r\n\r\n"
            let response = try await client.exchange(to: address, request: first + Array(second.utf8) + request.body)
            if oversized {
                #expect(response.status == nil)
                #expect(response.end == .peerClosed)
                #expect(await eventually { handler.cancellations == 1 })
            } else {
                #expect(response.status == 200)
                #expect(handler.cancellations == 0)
            }
            #expect(handler.requests.count == 1)
        }
    }
}
