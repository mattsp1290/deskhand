import DeskhandCore
import NIOHTTP1
import Testing

@testable import DeskhandServer

/// Contract 2.2 to 2.4 against the whole stack: a request that fails the TLS handshake or one of
/// checks 5 to 7 never reaches a tool, and a credential rotation keeps the records and the lease.
@Suite("end to end: transport and credentials", .timeLimit(.minutes(2)))
struct TransportEndToEndTests {
    /// Nothing ran: no event, no record, no action log entry.
    static func expectNothingRan(_ stack: DeskhandStack, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        #expect(stack.desk.posted.isEmpty, sourceLocation: sourceLocation)
        #expect(try await stack.lookUp("op-1") == .null, sourceLocation: sourceLocation)
        #expect(await stack.entries.isEmpty, sourceLocation: sourceLocation)
    }

    @Test(
        "a refused client certificate fails the handshake and reaches no tool",
        arguments: [TestPKI.Client.wrongCA, .wrongSubject, .serverAuthOnly, .noExtendedKeyUsage, nil])
    func wrongCertificate(_ client: TestPKI.Client?) async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let effect = WireRequest.tool(
                "keyboard", Wire.type("hi", frame: frame, "op-1"), token: CredentialDirectory.firstToken)
            let response = try await stack.send(effect, as: client)
            #expect(response.status == nil)
            try await Self.expectNothingRan(stack)
            switch client {
            case .wrongSubject?: #expect(stack.events.refusals == [.unexpectedSubject("CN=someone-else,O=forge")])
            case .noExtendedKeyUsage?: #expect(stack.events.refusals == [.missingClientAuthUsage])
            default: #expect(stack.events.refusals.isEmpty, "BoringSSL refuses these before the D11 checks run")
            }
        }
    }

    @Test("a wrong token, an Origin or a bad Host is refused by status alone, before any tool")
    func refusedRequests() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let effect = WireRequest.tool(
                "keyboard", Wire.type("hi", frame: frame, "op-1"), token: CredentialDirectory.firstToken)
            let refused: [(String, TestRequest, HTTPResponseStatus)] = [
                (
                    "another token", effect.setting("Authorization", to: "Bearer \(CredentialDirectory.secondToken)"),
                    .unauthorized
                ),
                ("no token", effect.setting("Authorization", to: nil), .unauthorized),
                ("Origin", effect.setting("Origin", to: "https://crew.forge.svc"), .forbidden),
                (
                    "an IP literal Host", effect.setting("Host", to: "127.0.0.1:\(ListenerHarness.servicePort)"),
                    .misdirectedRequest
                ),
                ("another Host", effect.setting("Host", to: "deskhand-other.forge.svc:8443"), .misdirectedRequest),
            ]
            for (name, request, status) in refused {
                let response = try await stack.send(request)
                #expect(response.status == status, "\(name)")
                #expect(response.outcome.response?.body.isEmpty == true, "\(name)")
                if status == .unauthorized {
                    #expect(response.headers?["WWW-Authenticate"] == [#"Bearer realm="deskhand""#])
                }
            }
            try await Self.expectNothingRan(stack)

            let accepted = try await stack.send(effect)
            #expect(accepted.structuredContent?["status"] == "completed")
        }
    }

    @Test("a rotation: new connections get the new pair and token, the old token is refused, records carry over")
    func rotation() async throws {
        try await DeskhandStack.with { stack in
            let rotation = try RotationPKI.get()
            let (first, second) = (CredentialDirectory.firstToken, CredentialDirectory.secondToken)
            let frame = try await stack.ready()
            let arguments = Wire.type("hi", frame: frame, "op-1")
            #expect(try await stack.call("keyboard", arguments).structuredContent?["status"] == "completed")
            let posted = stack.desk.posted.count
            #expect(
                try await PresentedCertificate.serialNumber(at: stack.address, pki: stack.pki)
                    == rotation.serialNumber(.first))

            try await stack.session(token: first) { session in
                #expect(await session.call("status").status == .ok)
                try stack.credentials.install(.second)
                try stack.credentials.writeToken(second)
                #expect(!(await stack.reloader.reload()).credentialsWarning)

                // The open connection keeps its TLS session; each request is judged on the token now.
                let replay = await session.send(WireRequest.tool("keyboard", arguments, token: second))
                #expect(replay.structuredContent?["replayed"] == true)
                #expect(await session.call("status").status == .unauthorized)
            }
            #expect(
                try await PresentedCertificate.serialNumber(at: stack.address, pki: stack.pki)
                    == rotation.serialNumber(.second))
            #expect(try await stack.call("status", token: first).status == .unauthorized)
            let lease = try await stack.call("status", ["holder_id": .string(Wire.holder)], token: second)
            #expect(lease.structuredContent?["lease"]?["held_by_caller"] == true)
            let replay = try await stack.call("keyboard", arguments, token: second)
            #expect(replay.structuredContent?["replayed"] == true)
            #expect(stack.desk.posted.count == posted)

            // A refused pair keeps the one in use and raises credentials_warning until fixed.
            try stack.credentials.install(.wrongCA)
            #expect(await stack.reloader.reload().certificateRejection == .notIssuedByCA)
            #expect(try await stack.reportedConditions(token: second).contains("credentials_warning"))
            #expect(
                try await PresentedCertificate.serialNumber(at: stack.address, pki: stack.pki)
                    == rotation.serialNumber(.second))
            try stack.credentials.install(.second)
            await stack.reloader.reload()
            #expect(!(try await stack.reportedConditions(token: second)).contains("credentials_warning"))
        }
    }

    @Test("protocol faults are JSON-RPC errors with their status; a fault inside arguments is invalid_argument")
    func protocolFaults() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let effect = MCPTestRequest.tool("keyboard", Wire.type("hi", frame: frame, "op-1"))
            let faults: [(String, MCPTestRequest, HTTPResponseStatus, Int)] = [
                ("unknown tool", .tool("teleport", [:]), .ok, -32_602),
                ("Mcp-Name differs", effect.with { $0.name = ["pointer"] }, .badRequest, -32_020),
                ("unsupported version", effect.with { $0.protocolVersion = ["2025-06-18"] }, .badRequest, -32_022),
                ("unknown method", .call("resources/list"), .notFound, -32_601),
            ]
            for (name, request, status, code) in faults {
                let response = try await stack.send(
                    MCPListenerTests.mcpRequest(request)
                        .setting("Authorization", to: "Bearer \(CredentialDirectory.firstToken)"))
                #expect(response.status == status, "\(name)")
                #expect(response.mcp?.errorCode == code, "\(name)")
                #expect(response.mcp?.result == nil, "\(name)")
            }
            #expect(stack.desk.posted.isEmpty)
            #expect(await stack.entries.isEmpty)

            let meta = #"{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}"#
            let duplicate = MCPTestRequest.raw(
                #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"_meta":\#(meta),"name":"keyboard","#
                    + #""arguments":{"holder_id":"crew:alpha","holder_id":"crew:beta","frame_id":"\#(frame)","#
                    + #""operation_id":"op-1","action":{"type":"type","text":"hi"}}}}"#,
                method: "tools/call", name: "keyboard")
            let response = try await stack.send(
                MCPListenerTests.mcpRequest(duplicate)
                    .setting("Authorization", to: "Bearer \(CredentialDirectory.firstToken)"))
            ContractShape.expectToolError(response, "invalid_argument")
            #expect(response.structuredContent?["operation_id"] == "op-1")
            #expect(stack.desk.posted.isEmpty)
            #expect(await stack.refusalCodes == [.invalidArgument])
        }
    }

    @Test("a re-issued client certificate with the same subject is the same principal")
    func sameSubjectRotation() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let arguments = Wire.type("hi", frame: frame, "op-1")
            let first = try await stack.call("keyboard", arguments, as: .reissued)
            #expect(first.structuredContent?["status"] == "completed")
            let replay = try await stack.call("keyboard", arguments, as: .valid)
            #expect(replay.structuredContent?["replayed"] == true)
            let status = try await stack.call("status", ["holder_id": .string(Wire.holder)], as: .reissued)
            #expect(status.structuredContent?["lease"]?["held_by_caller"] == true)
            let principals = await stack.entries.map(\.principal)
            #expect(!principals.isEmpty)
            #expect(Set(principals) == [Principal(certificateSubject: TestPKI.expectedSubject)])
        }
    }
}
