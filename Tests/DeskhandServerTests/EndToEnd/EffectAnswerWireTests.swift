import DeskhandCore
import DeskhandTestSupport
import NIOCore
import Testing

@testable import DeskhandServer

actor StackActionLog: ActionLogClient {
    private let memory = InMemoryActionLog()
    private var hook: (@Sendable (ActionLogEntryKind) async -> Void)?

    var entries: [ActionLogEntry] { get async { await memory.entries } }

    func onAppend(_ hook: @escaping @Sendable (ActionLogEntryKind) async -> Void) { self.hook = hook }

    func append(_ line: ActionLogLine) async throws(ActionLogFailure) {
        await hook?(line.entry.kind)
        try await memory.append(line)
    }
}

@Suite("Effect answers close without HTTP bytes", .timeLimit(.minutes(2)))
struct EffectAnswerWireTests {
    static func exchange(_ request: TestRequest, address: SocketAddress, pki: TestPKI) async throws
        -> ResumingTLSClient.Exchange
    {
        let identity = pki.identity(.valid)
        let client = try ResumingTLSClient(
            caPath: pki.caPath, certificatePath: identity.certificatePath, keyPath: identity.keyPath)
        let request = request.setting("Connection", to: "close")
        var head = "POST /mcp HTTP/1.1\r\n"
        for (name, value) in request.headers { head += "\(name): \(value)\r\n" }
        return try await client.exchange(
            port: try #require(address.port), serverName: TestPKI.serverName,
            request: Array((head + "\r\n").utf8) + request.body, offering: nil)
    }

    static func request(_ tool: String, _ arguments: JSONObject) -> TestRequest {
        WireRequest.tool(tool, arguments, token: CredentialDirectory.firstToken)
    }

    static var strict: TestRequest {
        let body =
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"pointer","arguments":{"operation_id":"x","operation_id":"y"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        return MCPListenerTests.mcpRequest(.raw(body, method: "tools/call", name: "pointer"))
            .setting("Authorization", to: "Bearer \(CredentialDirectory.firstToken)")
    }

    @Test(arguments: [false, true])
    func frameFailureClosesWire(_ timeout: Bool) async throws {
        let entered = Latch()
        let proceed = Latch()
        let options = DeskhandStack.Options(
            waitLimit: .milliseconds(40),
            frameCheck: {
                entered.open()
                await proceed.wait()
                return .stale(.unknown, sha256: nil)
            })
        try await DeskhandStack.with(options) { stack in
            let frame = try await stack.ready()
            let request = Self.request("pointer", Wire.click(frame: frame, "op-1"))
            let pending = Task { try await Self.exchange(request, address: stack.address, pki: stack.pki) }
            await entered.wait()
            await stack.executor.beginStop()
            if !timeout { proceed.open() }
            let response = try await pending.value
            proceed.open()
            #expect(response.bytes.isEmpty)
            #expect(stack.desk.posted.isEmpty)
            _ = await stack.executor.awaitStopEntries()
        }
    }

    @Test func completedRecordReplaysAfterRestart() async throws {
        let first = try await DeskhandStack.start()
        let arguments: JSONObject
        let state: StateDirectory
        do {
            let frame = try await first.ready()
            arguments = Wire.type("x", frame: frame, "completed")
            await first.log.base.onAppend { kind in
                if kind == .outcome { await first.executor.beginStop() }
            }
            let response = try await Self.exchange(
                Self.request("keyboard", arguments), address: first.address, pki: first.pki)
            #expect(response.bytes.isEmpty)
            _ = await first.executor.awaitStopEntries()
            state = try first.state.copy()
        } catch {
            await first.stop()
            throw error
        }
        await first.stop()
        try await DeskhandStack.with(.init(state: state)) { next in
            let replay = try await next.call("keyboard", arguments)
            #expect(replay.structuredContent?["status"] == "completed")
            #expect(replay.structuredContent?["replayed"] == true)
            #expect(replay.structuredContent?["events_posted"] == 2)
            #expect(next.desk.posted.isEmpty)
        }
    }

    @Test func readFinishesWhenStopStartsDuringCapture() async throws {
        try await DeskhandStack.with { stack in
            try await stack.acquire()
            stack.platform.capturer.configure { behavior in
                behavior.during = { await stack.executor.beginStop() }
            }
            let response = try await stack.call("screenshot", ["holder_id": .string(Wire.holder)])
            #expect(response.status == .ok)
            #expect(response.isError == false)
            #expect(response.structuredContent?["frame_id"] != nil)
        }
    }

    @Test(arguments: ["outcome", "early", "schema", "strict"])
    func stopWhileLogging(_ path: String) async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            if path == "early" { await stack.hold([.locked]) }
            let kind: ActionLogEntryKind = path == "outcome" ? .outcome : .refusal
            await stack.log.base.onAppend { entry in
                if entry == kind { await stack.executor.beginStop() }
            }
            let request =
                path == "strict"
                ? Self.strict
                : Self.request(
                    "keyboard", path == "schema" ? ["operation_id": "bad"] : Wire.type("x", frame: frame, "op-1"))
            let response = try await Self.exchange(request, address: stack.address, pki: stack.pki)
            #expect(response.bytes.isEmpty)
            #expect(await stack.executor.isStopping)
            _ = await stack.executor.awaitStopEntries()
            #expect(await stack.entries.map(\.kind) == (path == "outcome" ? [.intent, .outcome] : [.refusal]))
            #expect(stack.desk.posted.count == (path == "outcome" ? 2 : 0))
            let read = try await stack.call("status")
            #expect(read.status == .ok)
            if path == "outcome" {
                #expect(try await stack.lookUp("op-1") == ["status": "completed", "events_posted": 2])
            }
        }
    }

    @Test(arguments: [PatchVerdict.changed, .unknown], [false, true])
    func stopWhileCheckingPatch(_ verdict: PatchVerdict, _ timeout: Bool) async throws {
        try await DeskhandStack.with(.init(waitLimit: .milliseconds(40))) { stack in
            let frame = try await stack.ready()
            let gate = Latch()
            stack.desk.change {
                $0.patch = verdict
                $0.onVerify = {
                    await stack.executor.beginStop()
                    if timeout { await gate.wait() }
                }
            }
            let response = try await Self.exchange(
                Self.request("pointer", Wire.click(frame: frame, "op-1")), address: stack.address, pki: stack.pki)
            gate.open()
            #expect(response.bytes.isEmpty)
            #expect(stack.desk.posted.isEmpty)
            _ = await stack.executor.awaitStopEntries()
            #expect(try await stack.lookUp("op-1") == .null)
        }
    }

    @Test func postStopValidSchemaStrictAndRead() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            await stack.executor.beginStop()
            for request in [
                Self.request("keyboard", Wire.type("x", frame: frame, "op-1")),
                Self.request("pointer", ["operation_id": "bad"]), Self.strict,
            ] {
                let response = try await Self.exchange(request, address: stack.address, pki: stack.pki)
                #expect(response.bytes.isEmpty)
            }
            #expect(stack.desk.posted.isEmpty)
            #expect(await stack.entries.isEmpty)
            #expect(try await stack.lookUp("op-1") == .null)
            let badRead = try await stack.call("status", ["holder_id": 3])
            ContractShape.expectToolError(badRead, "invalid_argument")
            #expect(try await stack.call("status").status == .ok)
        }
    }

    @Test(arguments: [RefusalWireDispatcher.Fault.missingNode, .digest, .serialization], [false, true])
    func preparationAndFallback(_ fault: RefusalWireDispatcher.Fault, _ stopping: Bool) async throws {
        let harness = try ToolHarness()
        let adapter = RefusalWireDispatcher(base: harness.dispatcher, fault: fault)
        if stopping { await harness.executor.beginStop() }
        try await ListenerHarness.withListener(handler: MCPHandler(dispatcher: adapter)) { address, pki, _ in
            let request = MCPListenerTests.mcpRequest(.tool("pointer", ToolCallTests.pointerArguments))
            let response = try await Self.exchange(request, address: address, pki: pki)
            if stopping {
                #expect(response.bytes.isEmpty)
            } else {
                #expect(response.status == 200)
                #expect(String(decoding: response.bytes, as: UTF8.self).contains("internal_error"))
            }
        }
        #expect(harness.desk.posted.isEmpty)
        #expect(await harness.log.entries.isEmpty)
    }
}

struct RefusalWireDispatcher: ToolDispatcher {
    enum Fault: Sendable { case missingNode, digest, serialization }
    let base: DeskhandDispatcher
    let fault: Fault

    func status(_ arguments: StatusArguments, caller: ToolCaller) async throws(ToolError) -> StatusResult {
        try await base.status(arguments, caller: caller)
    }
    func displays(caller: ToolCaller) async throws(ToolError) -> DisplaysResult {
        try await base.displays(caller: caller)
    }
    func screenshot(_ arguments: ScreenshotArguments, caller: ToolCaller) async throws(ToolError) -> CapturedScreenshot
    {
        try await base.screenshot(arguments, caller: caller)
    }
    func lease(_ arguments: LeaseArguments, caller: ToolCaller) async throws(ToolError) -> LeaseToolResult {
        try await base.lease(arguments, caller: caller)
    }
    func effect(_ arguments: EffectCallArguments, received: JSONObject, caller: ToolCaller) async -> EffectAnswer {
        switch fault {
        case .missingNode:
            return await base.effect(
                arguments, received: received, caller: ToolCaller(principal: caller.principal, nodeAddress: nil))
        case .digest:
            var received = received
            received["nonfinite"] = .number(.infinity)
            return await base.effect(arguments, received: received, caller: caller)
        case .serialization:
            return .completed(ToolCallTests.effect(at: GlobalPoint(x: .infinity, y: 0)))
        }
    }
    func refusal(_ refusal: ToolRefusal, tool: ToolName, handles: EffectHandles, caller: ToolCaller) async -> ToolError?
    {
        await base.refusal(refusal, tool: tool, handles: handles, caller: caller)
    }
}

struct StackFrames: FrameSource {
    let owner: DeskOwner
    let check: (@Sendable () async -> FrameCheck)?

    func check(_ id: FrameID, in scope: FrameScope, for use: FrameUse, now: Timestamp) async -> FrameCheck {
        if let check { return await check() }
        return await owner.check(id, in: scope, for: use, now: now)
    }
}
