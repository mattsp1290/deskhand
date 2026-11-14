import DeskhandCore
import DeskhandTestSupport
import Testing

@testable import DeskhandServer

@Suite("pointer and keyboard through the dispatcher")
struct EffectToolTests {
    /// A harness holding the lease, with one frame of the main display.
    static func ready(ttlMs: Int = 30_000) async throws -> (ToolHarness, FrameID) {
        let harness = try ToolHarness()
        try await harness.lease(.acquire(ttlMs: ttlMs))
        return (harness, try await harness.screenshot().result.frameID)
    }

    static func press(_ key: String, holdMs: Int, frame: FrameID, operation: String = "op-press") -> JSONObject {
        [
            "holder_id": .string(ToolFixture.holder.rawValue), "frame_id": .string(frame.rawValue),
            "operation_id": .string(operation),
            "action": ["type": "press", "key": .string(key), "hold_ms": .number(Double(holdMs))],
        ]
    }

    @Test("a call runs to completion with what deskhand measured")
    func completes() async throws {
        let (harness, frame) = try await Self.ready()
        let answer = try await harness.type("hi", frame: frame)
        guard case .completed(let result) = answer else {
            Issue.record("expected a completed call, got \(answer)")
            return
        }
        #expect(result.operationID == OperationID("op-1"))
        #expect(result.frameID == frame)
        #expect(!result.replayed)
        #expect(result.eventsPosted > 0)
        #expect(result.eventsPosted == harness.desk.posted.count)
        #expect(result.measured.frontmostApp == ToolFixture.textEdit.appRef)
        #expect(result.measured.targetApp == ToolFixture.textEdit.appRef)
        #expect(result.measured.windowTitle == "notes.txt")
        let entries = await harness.log.entries
        #expect(entries.map(\.kind) == [.intent, .outcome])
    }

    @Test("a repeat returns the stored result and posts nothing")
    func replaysSuccess() async throws {
        let (harness, frame) = try await Self.ready()
        let first = try await harness.type("hi", frame: frame)
        let posted = harness.desk.posted.count
        try await harness.lease(.release)
        let repeated = try await harness.type("hi", frame: frame)
        guard case .replayed(_, let content) = repeated else {
            Issue.record("expected a replay, got \(repeated)")
            return
        }
        var expected = try #require(first.structuredContent?.objectValue)
        expected["replayed"] = true
        #expect(content == .object(expected))
        #expect(!repeated.isError)
        #expect(ToolOutcome(repeated) == .replayed(content, isError: false))
        #expect(harness.desk.posted.count == posted)

        let conflict = try await harness.type("ho", frame: frame)
        #expect(conflict.code == .operationIDConflict)
        #expect(conflict.toolError?.operationView == OperationView(status: .completed, eventsPosted: posted))
    }

    @Test("a stored error is replayed with the state stored and the state now")
    func replaysError() async throws {
        let (harness, frame) = try await Self.ready(ttlMs: 5000)
        harness.clock.advance(byMilliseconds: 1000)
        let arguments = Self.press("a", holdMs: 5000, frame: frame)
        let call = EffectCallArguments.keyboard(try KeyboardArguments(arguments: arguments))
        let first = await harness.dispatcher.effect(call, received: arguments, caller: ToolFixture.caller)
        #expect(first.code == .leaseExpired)
        #expect(first.structuredContent?["replayed"] == false)
        let view = try #require(first.toolError?.operationView)
        #expect(view.status == .aborted)

        let repeated = await harness.dispatcher.effect(call, received: arguments, caller: ToolFixture.caller)
        guard case .replayed(_, let content) = repeated else {
            Issue.record("expected a replay, got \(repeated)")
            return
        }
        #expect(content["code"] == "lease_expired")
        #expect(content["state"] == "ok")
        #expect(content["replayed"] == true)
        #expect(content["current_state"] == "ok")
        #expect(content["operation"] == view.jsonValue)
        #expect(content["measured"] != nil)
        #expect(ToolOutcome(repeated).isError)

        let query = OperationQuery(holderID: ToolFixture.holder, operationID: OperationID("op-press")!)
        #expect(try await harness.status(StatusArguments(operation: query)).operation == .found(view))
    }

    @Test("a call whose task is already cancelled is never admitted")
    func cancelledNeverAdmits() async throws {
        let (harness, frame) = try await Self.ready()
        let task = Task { () async throws -> EffectAnswer in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await harness.type("hi", frame: frame)
        }
        let answer = try await task.value
        guard case .dropped = answer else {
            Issue.record("expected the call to be dropped, got \(answer)")
            return
        }
        #expect(harness.desk.posted.isEmpty)
        let query = OperationQuery(holderID: ToolFixture.holder, operationID: OperationID("op-1")!)
        #expect(try await harness.status(StatusArguments(operation: query)).operation == .notFound)
        #expect(await harness.log.entries.allSatisfy { $0.kind == .refusal })

        // The same operation_id is judged afresh on an open connection.
        guard case .completed = try await harness.type("hi", frame: frame) else {
            Issue.record("expected the repeat on an open connection to complete")
            return
        }
    }

    @Test("an effect is refused with the state's name before anything else")
    func stateFirst() async throws {
        let (harness, frame) = try await Self.ready()
        harness.hold([.secureInput])
        let answer = try await harness.type("hi", frame: frame)
        #expect(answer.code == .secureInput)
        #expect(answer.toolError?.operationID == OperationID("op-1"))
        #expect(harness.desk.posted.isEmpty)
    }

    static let badPointer = ArgumentError(at: JSONPointer(["action", "x"]), "must be an integer")
    static let handles = EffectHandles(arguments: [
        "holder_id": .string(ToolFixture.holder.rawValue), "operation_id": "op-1",
    ])

    @Test("invalid arguments of an effect: the state's name first, then invalid_argument with the record")
    func effectArgumentRefusals() async throws {
        let (harness, frame) = try await Self.ready()
        let refusal = { (caller: ToolCaller) in
            await harness.dispatcher.refusal(
                .invalidArguments(Self.badPointer), tool: .pointer, handles: Self.handles, caller: caller)
        }
        var error = await refusal(ToolFixture.caller)
        #expect(error.code == .invalidArgument)
        #expect(error.jsonValue["details"] == ["argument": "/action/x"])
        #expect(error.operationID == OperationID("op-1"))
        #expect(error.operation == nil)

        _ = try await harness.type("hi", frame: frame)
        error = await refusal(ToolFixture.caller)
        #expect(error.code == .invalidArgument)
        #expect(error.operationView?.status == .completed)
        #expect(await refusal(ToolFixture.otherCaller).operation == nil)

        harness.hold([.disarmed])
        error = await refusal(ToolFixture.caller)
        #expect(error.code == .disarmed)
        #expect(error.state == .disarmed)
        #expect(error.operationView?.status == .completed)
        #expect(await harness.log.entries.last?.kind == .refusal)
    }

    @Test("status and lease refuse only with invalid_argument; displays and screenshot put the state first")
    func readArgumentRefusals() async throws {
        let harness = try ToolHarness()
        harness.hold([.gated])
        let fault = ArgumentError(at: JSONPointer(["holder_id"]), "must be 1 to 128 characters")
        for tool in [ToolName.status, .lease] {
            let error = await harness.dispatcher.refusal(
                .invalidArguments(fault), tool: tool, handles: Self.handles, caller: ToolFixture.caller)
            #expect(error.code == .invalidArgument)
            #expect(error.state == .gated)
            #expect(error.operationID == nil)
        }
        for tool in [ToolName.displays, .screenshot] {
            let error = await harness.dispatcher.refusal(
                .invalidArguments(fault), tool: tool, handles: Self.handles, caller: ToolFixture.caller)
            #expect(error.code == .gated)
        }
        harness.hold([])
        let error = await harness.dispatcher.refusal(
            .invalidArguments(fault), tool: .screenshot, handles: Self.handles, caller: ToolFixture.caller)
        #expect(error.code == .disarmed)
    }

    @Test("an effect from a connection with no source address is internal_error")
    func noNodeAddress() async throws {
        let (harness, frame) = try await Self.ready()
        let caller = ToolCaller(principal: ToolFixture.principal, nodeAddress: nil)
        let answer = try await harness.type("hi", frame: frame, caller: caller)
        #expect(answer.code == .internalError)
        #expect(answer.toolError?.operationID == OperationID("op-1"))
        #expect(harness.desk.posted.isEmpty)
        let refusal = await harness.dispatcher.refusal(
            .invalidArguments(Self.badPointer), tool: .pointer, handles: Self.handles, caller: caller)
        #expect(refusal.code == .invalidArgument)
        #expect(refusal.operationID == OperationID("op-1"))
        harness.hold([.locked])
        let blocked = await harness.dispatcher.refusal(
            .invalidArguments(Self.badPointer), tool: .pointer, handles: Self.handles, caller: caller)
        #expect(blocked.code == .locked)
    }

    @Test("a lease call ends the effect executing under the lease it ends")
    func releaseStopsTheEffect() async throws {
        let (harness, frame) = try await Self.ready()
        let arguments = Self.press("a", holdMs: 5000, frame: frame)
        let call = EffectCallArguments.keyboard(try KeyboardArguments(arguments: arguments))
        let dispatcher = harness.dispatcher
        let released = Counter()
        harness.desk.change {
            $0.onSleep = {
                let result = try? await dispatcher.lease(
                    LeaseArguments(holderID: ToolFixture.holder, command: .release), caller: ToolFixture.caller)
                if result?.result.outcome == .released { released.increment() }
            }
        }
        let answer = await dispatcher.effect(call, received: arguments, caller: ToolFixture.caller)
        #expect(released.value == 1)
        #expect(answer.code == .leaseNotHeld)
        #expect(answer.toolError?.operationView?.status == .aborted)
    }
}
