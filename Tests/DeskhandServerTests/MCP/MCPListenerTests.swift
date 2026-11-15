import DeskhandCore
import NIOCore
import NIOHTTP1
import Testing

@testable import DeskhandServer

@Suite(.timeLimit(.minutes(1))) struct MCPListenerTests {
    static func mcpRequest(_ request: MCPTestRequest) -> TestRequest {
        var test = TestRequest.valid(body: request.body)
        for (name, values) in [
            ("MCP-Protocol-Version", request.protocolVersion), ("Mcp-Method", request.method),
            ("Mcp-Name", request.name),
        ] {
            test.headers.removeAll { $0.0.lowercased() == name.lowercased() }
            test.headers += values.map { (name, $0) }
        }
        return test
    }

    @Test(arguments: [HTTPMethod.GET, .DELETE])
    func getAndDeleteAreNotAllowed(_ method: HTTPMethod) async throws {
        let dispatcher = FakeDispatcher()
        try await ListenerHarness.withListener(handler: MCPHandler(dispatcher: dispatcher)) { address, pki, _ in
            var request = Self.mcpRequest(.call("tools/list"))
            request.method = method
            if method == .GET { request.body = [] }
            let response = try #require(try await TestClient.roundTrip(request, to: address, pki: pki).response)
            #expect(response.status == .methodNotAllowed)
            #expect(response.headers["Allow"] == ["POST"])
            #expect(response.body.isEmpty)
            #expect(dispatcher.calls.isEmpty)
        }
    }

    @Test func toolsListIsServedAsJSON() async throws {
        try await ListenerHarness.withListener(handler: MCPHandler(dispatcher: FakeDispatcher())) { address, pki, _ in
            let request = Self.mcpRequest(.call("tools/list", id: "list"))
            let response = try #require(try await TestClient.roundTrip(request, to: address, pki: pki).response)
            #expect(response.status == .ok)
            #expect(response.headers["Content-Type"] == ["application/json"])
            let json = try JSONValue(parsing: response.body)
            #expect(json["id"] == "list")
            guard case .array(let tools)? = json["result"]?["tools"] else {
                Issue.record("no tools in \(json)")
                return
            }
            #expect(tools.count == ToolName.allCases.count)
        }
    }

    @Test func headerMismatchIs400WithAJSONRPCBody() async throws {
        try await ListenerHarness.withListener(handler: MCPHandler(dispatcher: FakeDispatcher())) { address, pki, _ in
            let request = Self.mcpRequest(.tool("status").with { $0.name = ["pointer"] })
            let response = try #require(try await TestClient.roundTrip(request, to: address, pki: pki).response)
            #expect(response.status == .badRequest)
            #expect(try JSONValue(parsing: response.body)["error"]?["code"] == -32_020)
        }
    }

    @Test func notificationIsAcceptedWithNoBody() async throws {
        try await ListenerHarness.withListener(handler: MCPHandler(dispatcher: FakeDispatcher())) { address, pki, _ in
            let request = Self.mcpRequest(.call("tools/list", id: nil))
            let response = try #require(try await TestClient.roundTrip(request, to: address, pki: pki).response)
            #expect(response.status == .accepted)
            #expect(response.body.isEmpty)
        }
    }

    @Test func closingTheConnectionCancelsTheCall() async throws {
        let dispatcher = FakeDispatcher(.waitForCancellation)
        try await ListenerHarness.withListener(handler: MCPHandler(dispatcher: dispatcher)) { address, pki, _ in
            let request = Self.mcpRequest(.tool("pointer", ToolCallTests.pointerArguments))
            try await TestClient.withConnection(to: address, pki: pki, as: .valid) { connection in
                #expect(await connection.send(request))
                var started = dispatcher.started.makeAsyncIterator()
                _ = await started.next()
            }
            #expect(await dispatcher.waitForCancellation())
            #expect(dispatcher.calls.count == 1)
        }
    }

    @Test(arguments: HangUp.allCases)
    func hangingUpWithoutCloseNotifyCancelsTheCall(_ hangUp: HangUp) async throws {
        let dispatcher = FakeDispatcher(.waitForCancellation)
        try await ListenerHarness.withListener(handler: MCPHandler(dispatcher: dispatcher)) { address, pki, _ in
            let client = try await HangingUpClient.connect(to: address, pki: pki)
            try await client.send(Self.mcpRequest(.tool("pointer", ToolCallTests.pointerArguments)))
            var started = dispatcher.started.makeAsyncIterator()
            _ = await started.next()

            try await client.hangUp(hangUp)
            #expect(await dispatcher.waitForCancellation(limit: HangUpTests.bound))
            #expect(dispatcher.calls.count == 1)
            try? await client.channel.close()
        }
    }
}
