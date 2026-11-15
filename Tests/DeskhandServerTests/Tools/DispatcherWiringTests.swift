import DeskhandCore
import NIOCore
import Testing

@testable import DeskhandServer

@Suite("dispatcher wiring")
struct DispatcherWiringTests {
    @Test("the action log names the node an address came from, IPv4-mapped or not")
    func nodeAddressOfASocket() throws {
        let v4 = try SocketAddress(ipAddress: "10.0.0.21", port: 8443)
        #expect(NodeAddress(socketAddress: v4) == NodeAddress("10.0.0.21"))
        let mapped = try SocketAddress(ipAddress: "::ffff:10.0.0.21", port: 8443)
        #expect(NodeAddress(socketAddress: mapped) == NodeAddress("10.0.0.21"))
        let v6 = try SocketAddress(ipAddress: "fd00::21", port: 8443)
        #expect(NodeAddress(socketAddress: v6) == NodeAddress("fd00::21"))
        #expect(NodeAddress(socketAddress: try SocketAddress(unixDomainSocketPath: "/tmp/deskhand.sock")) == nil)
    }

    static func call(_ harness: ToolHarness, _ tool: String, _ arguments: JSONObject) async -> MCPTestResponse {
        let handler = MCPHandler(dispatcher: harness.dispatcher, serverVersion: "0.1.0")
        let request = MCPTestRequest.tool(tool, arguments)
        let authenticated = AuthenticatedRequest(
            principal: ToolFixture.principal, nodeAddress: ToolFixture.node,
            headers: MCPRequestHeaders(
                protocolVersion: request.protocolVersion, method: request.method, name: request.name),
            body: request.body)
        return MCPTestResponse(await handler.handle(authenticated))
    }

    @Test("lease, screenshot, keyboard and a repeat, end to end through the MCP layer")
    func endToEnd() async throws {
        let harness = try ToolHarness()
        let lease = await Self.call(harness, "lease", ["op": "acquire", "holder_id": "crew:alpha"])
        #expect(lease.isError == false)
        #expect(lease.structuredContent?["lease_result"]?["outcome"] == "acquired")

        let shot = await Self.call(harness, "screenshot", ["holder_id": "crew:alpha"])
        let frame = try #require(shot.structuredContent?["frame_id"]?.stringValue)

        let arguments: JSONObject = [
            "holder_id": "crew:alpha", "frame_id": .string(frame), "operation_id": "crew-call-17",
            "action": ["type": "type", "text": "hello"],
        ]
        let typed = await Self.call(harness, "keyboard", arguments)
        #expect(typed.isError == false)
        #expect(typed.structuredContent?["status"] == "completed")
        #expect(typed.structuredContent?["replayed"] == false)
        #expect(typed.structuredContent?["measured"]?["window_title"] == "notes.txt")
        let entries = await harness.log.entries
        #expect(entries.count == 2)
        for entry in entries {
            switch entry {
            case .intent(let intent): #expect(intent.nodeAddress == ToolFixture.node)
            case .outcome(let outcome): #expect(outcome.nodeAddress == ToolFixture.node)
            case .refusal: Issue.record("no call was refused")
            }
        }

        let repeated = await Self.call(harness, "keyboard", arguments)
        #expect(repeated.isError == false)
        #expect(repeated.structuredContent?["replayed"] == true)
        #expect(repeated.contentText == repeated.structuredContent)

        let lookup = await Self.call(
            harness, "status", ["operation": ["holder_id": "crew:alpha", "operation_id": "crew-call-17"]])
        #expect(lookup.structuredContent?["operation"]?["status"] == "completed")

        let invalid = await Self.call(
            harness, "keyboard",
            [
                "holder_id": "crew:alpha", "frame_id": .string(frame), "operation_id": "crew-call-18",
                "action": ["type": "type", "text": "line\n"],
            ])
        #expect(invalid.isError == true)
        #expect(invalid.structuredContent?["code"] == "invalid_argument")
        #expect(invalid.structuredContent?["operation_id"] == "crew-call-18")
        #expect(await harness.log.entries.last?.kind == .refusal)
    }
}
