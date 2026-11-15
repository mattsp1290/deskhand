import DeskhandTestSupport
import Testing

@testable import DeskhandCore

@Suite("Effect answers settle before stop", .timeLimit(.minutes(1)))
struct EffectAnswerStopTests {
    static func context(_ harness: Harness, node: NodeAddress? = ExecutorFixture.node) -> EffectRefusalContext {
        EffectRefusalContext(
            tool: .keyboard,
            handles: EffectHandles(arguments: [
                "holder_id": .string(ExecutorFixture.holder.rawValue), "operation_id": "op-1",
                "frame_id": .string(harness.frameID),
            ]), principal: ExecutorFixture.principal, nodeAddress: node)
    }

    static func settled(_ executor: InputExecutor) async {
        _ = await executor.stop()
        _ = await executor.awaitStopEntries()
        #expect(await executor.callsAnswering == 0)
        #expect(await executor.refusalsHeld == 0)
        #expect(await executor.stopWaiters.isEmpty)
        #expect(await !executor.isInSection)
    }

    @Test(arguments: [ActionLogEntryKind.outcome, .refusal])
    func stopDuringLog(kind: ActionLogEntryKind) async throws {
        let harness = try Harness()
        let gate = Gate()
        await harness.onLog(kind) { await gate.pass() }
        if kind == .refusal { ExecutorStopTests.lock(harness.mac) }
        let call = try harness.keyboard(["type": "type", "text": "x"])
        let pending = Task { await harness.executor.perform(call) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        #expect(await harness.executor.callsAnswering == 1)
        await harness.executor.beginStop()
        let entries = Task { await harness.executor.awaitStopEntries() }
        while await harness.executor.stopWaiters.isEmpty { await Task.yield() }
        #expect(await !harness.executor.isInSection)
        await gate.open()
        #expect(await pending.value.structuredContent == nil)
        _ = await entries.value
        await Self.settled(harness.executor)
        if kind == .outcome {
            #expect(try await harness.status() == .found(OperationView(status: .completed, eventsPosted: 2)))
            let restarted = try ExecutorStopTests.restarted(harness)
            let replay = await restarted.executor.perform(call)
            #expect(replay.structuredContent?["status"] == "completed")
            #expect(replay.structuredContent?["replayed"] == true)
            #expect(harness.mac.posted.count == 2)
        } else {
            #expect(harness.mac.posted.isEmpty)
            #expect(await harness.logEntries.map(\.kind) == [.refusal])
        }
    }

    @Test func publicRefusalCountsWhileLogging() async throws {
        let harness = try Harness()
        let gate = Gate()
        await harness.onLog(.refusal) { await gate.pass() }
        let context = Self.context(harness)
        let pending = Task {
            await harness.executor.refusal(
                .invalidArguments(ArgumentError(at: JSONPointer([]), "bad")), context: context)
        }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        #expect(await harness.executor.callsAnswering == 1)
        await harness.executor.beginStop()
        let entries = Task { await harness.executor.awaitStopEntries() }
        while await harness.executor.stopWaiters.isEmpty { await Task.yield() }
        await gate.open()
        #expect(await pending.value == nil)
        _ = await entries.value
        await Self.settled(harness.executor)
        #expect(await harness.logEntries.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func frameCheck(stopping: Bool, timeout: Bool) async throws {
        let gate = Gate()
        let limits = ManualWaitLimits()
        let harness = try Harness(frames: FakeFrames(gate: gate), waitTimer: limits)
        let call = try harness.pointer(["type": "move", "x": 1, "y": 1], frame: "frm_AAAAAAAAAAAAAAAAAAAAAA")
        let pending = Task { await harness.executor.perform(call) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        if stopping { await harness.executor.beginStop() }
        let answer: EffectAnswer
        if timeout {
            answer = await limits.passing { await pending.value }
            await gate.open()
        } else {
            await gate.open()
            answer = await pending.value
        }
        if stopping {
            #expect(answer.structuredContent == nil)
        } else {
            #expect(answer.code == (timeout ? .internalError : .staleFrame))
        }
        #expect(harness.mac.posted.isEmpty)
        await Self.settled(harness.executor)
    }

    @Test(arguments: [PatchVerdict.changed, .unknown], [false, true])
    func patchCheck(verdict: PatchVerdict, timeout: Bool) async throws {
        let gate = Gate()
        let limits = ManualWaitLimits()
        let mac = FakeMac {
            $0.patchGate = gate
            $0.patchVerdict = verdict
        }
        let harness = try Harness(mac: mac, waitTimer: limits)
        let call = try harness.pointer(["type": "move", "x": 1, "y": 1])
        let pending = Task { await harness.executor.perform(call) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        await harness.executor.beginStop()
        if timeout {
            #expect(await limits.passing { await pending.value }.structuredContent == nil)
            await gate.open()
        } else {
            await gate.open()
            #expect(await pending.value.structuredContent == nil)
        }
        #expect(mac.posted.isEmpty)
        await Self.settled(harness.executor)
    }

    @Test func postStopSkipsEveryRefusalAndCall() async throws {
        let loader = FakeStoreLoader()
        loader.failNextLoad = true
        let harness = try Harness(loader: loader)
        await harness.executor.beginStop()
        let answer = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "x"]))
        #expect(answer.structuredContent == nil)
        #expect(await !harness.executor.storesAvailable)
        let reasons: [EffectRefusal] = [
            .invalidArguments(ArgumentError(at: JSONPointer([]), "bad")), .missingNodeAddress,
            .digestUnavailable, .unencodableResult,
        ]
        for reason in reasons {
            #expect(await harness.executor.refusal(reason, context: Self.context(harness)) == nil)
        }
        #expect(await harness.logEntries.isEmpty)
        #expect(harness.mac.posted.isEmpty)
        await Self.settled(harness.executor)
    }

    @Test(arguments: [false, true], [false, true])
    func refusalParity(blocked: Bool, missingNode: Bool) async throws {
        let harness = try Harness()
        _ = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "x"]))
        if blocked { ExecutorStopTests.lock(harness.mac) }
        let context = Self.context(harness, node: missingNode ? nil : ExecutorFixture.node)
        let invalid = ArgumentError(at: JSONPointer(["action"]), "must be an object")
        let cases: [(EffectRefusal, ToolErrorCode, String, Bool)] = [
            (
                .invalidArguments(invalid), blocked ? .locked : .invalidArgument,
                blocked ? "deskhand is locked." : invalid.description, true
            ),
            (
                .missingNodeAddress, blocked ? .locked : .internalError,
                blocked ? "deskhand is locked." : "The connection's source address could not be read.", true
            ),
            (.digestUnavailable, .internalError, "The request digest could not be computed.", false),
            (.unencodableResult, .internalError, "The tool result could not be serialized.", true),
        ]
        for (reason, code, message, hasRecord) in cases {
            let error = try #require(await harness.executor.refusal(reason, context: context))
            #expect(error.code == code)
            #expect(error.message == message)
            #expect(error.state == (blocked ? .locked : .ok))
            #expect(error.operationID == OperationID("op-1"))
            #expect(
                error.operation == (hasRecord ? .existing(OperationView(status: .completed, eventsPosted: 2)) : nil))
        }
        #expect(
            await harness.logEntries.map(\.kind)
                == (missingNode ? [.intent, .outcome] : [.intent, .outcome, .refusal]))
        #expect(harness.mac.posted.count == 2)
        #expect(await harness.executor.callsAnswering == 0)
    }

}
