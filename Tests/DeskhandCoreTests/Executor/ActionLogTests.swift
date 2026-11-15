import DeskhandCore
import Testing

@Suite("Executor: the action log", .timeLimit(.minutes(1)))
struct ActionLogTests {
    static func answer(of call: EffectCall, on harness: Harness, after gate: Gate, limits: ManualWaitLimits) async
        -> EffectAnswer?
    {
        let executor = harness.executor
        let task = Task { await executor.perform(call) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        return await limits.passing { await finished(task) }
    }

    @Test("a final record write that fails still gets an outcome entry: failed, with the events posted")
    func finalRecordWriteFails() async throws {
        let loader = FakeStoreLoader()
        loader.faultAt = 8
        let harness = try Harness(loader: loader)
        let call = try harness.keyboard(["type": "type", "text": "hi"])
        let answer = await harness.executor.perform(call)
        #expect(answer.code == .internalError)
        #expect(answer.operation == OperationView(status: .failed, eventsPosted: 4))
        #expect(harness.mac.posted.count == 4)
        let entries = await harness.logEntries
        #expect(entries.map(\.kind) == [.intent, .outcome])
        guard case .outcome(let outcome)? = entries.last else { return }
        #expect(outcome.outcome == .failed(eventsPosted: 4))
        #expect(harness.mac.read(\.logAppends).last == true)

        #expect(await harness.executor.reloadUnavailableStores())
        let repeated = await harness.executor.perform(call)
        #expect(repeated.structuredContent?["code"] == "interrupted")
        #expect(harness.mac.posted.count == 4)
    }

    @Test("an intent the writer never acknowledges is log_unavailable once the wait runs out")
    func hungWriterRefusesIntent() async throws {
        let limits = ManualWaitLimits()
        let harness = try Harness(waitTimer: limits)
        let gate = Gate()
        await harness.onLog(.intent) { await gate.pass() }
        let answer = await Self.answer(
            of: try harness.pointer(["type": "click", "x": 3, "y": 4]), on: harness, after: gate, limits: limits)
        #expect(answer?.code == .logUnavailable)
        #expect(harness.mac.posted.isEmpty)
        #expect(harness.mac.read(\.logAppends).contains(false))
        #expect(await harness.executor.isInSection == false)
        #expect(try await harness.status() == .notFound)

        await harness.onLog(.intent, nil)
        let next = await harness.executor.perform(
            try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-2"))
        #expect(next.result?.eventsPosted == 1)
        await gate.open()
    }

    @Test("an outcome entry the writer never acknowledges does not hold the answer")
    func hungWriterReleasesAnswer() async throws {
        let limits = ManualWaitLimits()
        let harness = try Harness(waitTimer: limits)
        let gate = Gate()
        await harness.onLog(.outcome) { await gate.pass() }
        let answer = await Self.answer(
            of: try harness.pointer(["type": "move", "x": 1, "y": 1]), on: harness, after: gate, limits: limits)
        #expect(answer?.result?.eventsPosted == 1)
        #expect(harness.mac.read(\.logAppends) == [true, false])
        await gate.open()
    }

    @Test("an intent that lands after its wait ran out is followed, not preceded, by its refusal entry")
    func lateIntentIsFollowedByItsRefusal() async throws {
        let limits = ManualWaitLimits()
        let harness = try Harness(waitTimer: limits)
        let gate = Gate()
        await harness.onLog(.intent) { await gate.pass() }
        let answer = await Self.answer(
            of: try harness.pointer(["type": "move", "x": 1, "y": 1]), on: harness, after: gate, limits: limits)
        #expect(answer?.code == .logUnavailable)
        #expect(await harness.logEntries.isEmpty, "the refusal entry went ahead of the intent it answers")

        await gate.open()
        await harness.log.base.waitForEntries(2)
        let entries = await harness.logEntries
        #expect(entries.map(\.kind) == [.intent, .refusal])
        guard case .refusal(let refusal)? = entries.last else { return }
        #expect(refusal.code == .logUnavailable)
        #expect(refusal.operationID == OperationID("op-1"))
        #expect(refusal.frameSHA256 == ExecutorFixture.frameSHA256)
        #expect(harness.mac.posted.isEmpty)
    }

    @Test("an append that answers after its wait ran out reports its answer then")
    func lateAnswerIsReported() async throws {
        let limits = ManualWaitLimits()
        let harness = try Harness(waitTimer: limits)
        let gate = Gate()
        await harness.onLog(.outcome) { await gate.pass() }
        let answer = await Self.answer(
            of: try harness.pointer(["type": "move", "x": 1, "y": 1]), on: harness, after: gate, limits: limits)
        #expect(answer?.result?.eventsPosted == 1)
        #expect(harness.mac.read(\.logAppends) == [true, false])

        await gate.open()
        await harness.mac.waitForLogAppends(3)
        #expect(harness.mac.read(\.logAppends) == [true, false, true])
    }

    @Test("an append that runs out of time after a newer append succeeded does not set log_unavailable")
    func staleFailureIsDropped() async throws {
        let limits = ManualWaitLimits()
        let harness = try Harness(waitTimer: limits)
        let gate = Gate()
        await harness.onLog(.refusal) { await gate.pass() }
        let paused = ExecutorFixture.report([.paused], at: harness.mac.reading)
        harness.mac.change { $0.report = paused }
        let executor = harness.executor
        let refusedCall = try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-r")
        let refused = Task { await executor.perform(refusedCall) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()

        harness.mac.change { $0.report = ExecutorFixture.okReport }
        let admitted = await executor.perform(
            try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-ok"))
        #expect(admitted.result?.eventsPosted == 1)
        #expect(harness.mac.read(\.logAppends) == [true, true])
        let refusal = await limits.passing { await finished(refused) }
        #expect(refusal?.code == .paused)
        #expect(harness.mac.read(\.logAppends) == [true, true])

        await gate.open()
        await harness.log.base.waitForEntries(3)
        #expect(harness.mac.read(\.logAppends) == [true, true])
    }

    @Test("the section is free while an outcome entry waits for the writer")
    func sectionIsFreeWhileTheOutcomeEntryWaits() async throws {
        let limits = ManualWaitLimits()
        let harness = try Harness(waitTimer: limits)
        let gate = Gate()
        await harness.onLog(.outcome) { await gate.pass() }
        let executor = harness.executor
        let firstCall = try harness.pointer(["type": "move", "x": 1, "y": 1])
        let secondCall = try harness.pointer(["type": "move", "x": 2, "y": 2], operation: "op-2")
        let first = Task { await executor.perform(firstCall) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        let second = Task { await executor.perform(secondCall) }
        _ = await arrivals.next()
        let answers = await limits.passing { (await finished(first), await finished(second)) }
        #expect(answers.0?.result?.eventsPosted == 1)
        #expect(answers.1?.code != .busy)
        #expect(answers.1?.result?.eventsPosted == 1)
        await gate.open()
    }

    @Test("a frame check that does not answer refuses with internal_error, and frees the section")
    func hungFrameCheck() async throws {
        let limits = ManualWaitLimits()
        let gate = Gate()
        let harness = try Harness(frames: FakeFrames(gate: gate), waitTimer: limits)
        let answer = await Self.answer(
            of: try harness.pointer(["type": "move", "x": 1, "y": 1]), on: harness, after: gate, limits: limits)
        #expect(answer?.code == .internalError)
        #expect(harness.mac.posted.isEmpty)
        #expect(await harness.executor.isInSection == false)
        await gate.open()
    }

    @Test("a patch recapture that does not answer is stale_frame pixels_changed")
    func hungRecapture() async throws {
        let limits = ManualWaitLimits()
        let gate = Gate()
        let mac = FakeMac { $0.patchGate = gate }
        let harness = try Harness(mac: mac, waitTimer: limits)
        let answer = await Self.answer(
            of: try harness.pointer(["type": "click", "x": 3, "y": 4]), on: harness, after: gate, limits: limits)
        #expect(answer?.code == .staleFrame)
        #expect(answer?.details == ["reason": "pixels_changed", "point_index": 0])
        #expect(mac.posted.isEmpty)
        await gate.open()
    }

    @Test("a caller hanging up mid-operation does not cancel the outcome entry")
    func outcomeAfterHangUp() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        await harness.log.base.failWhenCancelled()
        let box = TaskBox()
        mac.change { $0.onSleep = { box.cancel() } }
        let call = try harness.keyboard(
            ["type": "press", "key": "k", "hold_ms": 300], connection: TaskCancellationLiveness())
        let executor = harness.executor
        let task = Task { await executor.perform(call) }
        box.hold(task)
        let answer = await finished(task)
        #expect(answer?.code == .cancelled)
        #expect(answer?.operation == OperationView(status: .aborted, eventsPosted: 1))
        #expect(mac.released == [.named(.k)])
        let entries = await harness.logEntries
        #expect(entries.map(\.kind) == [.intent, .outcome])
        guard case .outcome(let outcome)? = entries.last else { return }
        #expect(outcome.outcome == .aborted(.cancelled, eventsPosted: 1))
        #expect(mac.read(\.logAppends).allSatisfy { $0 })
    }

    @Test("a caller hanging up during admission: the intent is committed, the call dropped, the pair closed")
    func intentAfterHangUp() async throws {
        let gate = Gate()
        let harness = try Harness(frames: FakeFrames(gate: gate))
        await harness.log.base.failWhenCancelled()
        let call = try harness.pointer(["type": "move", "x": 1, "y": 1], connection: TaskCancellationLiveness())
        let executor = harness.executor
        let task = Task { await executor.perform(call) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        task.cancel()
        await gate.open()
        guard case .dropped? = await finished(task) else {
            Issue.record("not dropped")
            return
        }
        #expect(harness.mac.posted.isEmpty)
        let entries = await harness.logEntries
        #expect(entries.map(\.kind) == [.intent, .refusal])
        #expect(harness.mac.read(\.logAppends).allSatisfy { $0 }, "a hang-up was taken for an unreachable writer")
    }

    @Test("the cancelled entry of a call dropped after its intent names the intent's frame and frontmost app")
    func droppedEntryNamesTheFrame() async throws {
        let harness = try Harness()
        let answer = await harness.executor.perform(
            try harness.pointer(["type": "move", "x": 1, "y": 1], connection: FakeConnection(openReads: 1)))
        guard case .dropped = answer else {
            Issue.record("not dropped: \(String(describing: answer.code))")
            return
        }
        guard case .refusal(let refusal)? = await harness.logEntries.last else {
            Issue.record("no refusal entry")
            return
        }
        #expect(refusal.code == .cancelled)
        #expect(refusal.frameSHA256 == ExecutorFixture.frameSHA256)
        #expect(refusal.frontmostApp == ExecutorFixture.textEdit.appRef)
    }

    @Test("arguments that did not validate get a refusal entry with the code they were answered")
    func invalidArgumentsAreLogged() async throws {
        let harness = try Harness()
        let handles = EffectHandles(arguments: [
            "holder_id": .string(ExecutorFixture.holder.rawValue), "operation_id": "op-1", "action": "bad",
        ])
        let error = ArgumentError(at: JSONPointer(["action"]), "must be an object")
        _ = await harness.executor.refusal(
            for: error, tool: .keyboard, handles: handles, principal: ExecutorFixture.principal,
            nodeAddress: ExecutorFixture.node)
        let paused = ExecutorFixture.report([.paused], at: harness.mac.reading)
        harness.mac.change { $0.report = paused }
        _ = await harness.executor.refusal(
            for: error, tool: .keyboard, handles: handles, principal: ExecutorFixture.principal,
            nodeAddress: ExecutorFixture.node)
        let refusals = await harness.logEntries.compactMap { entry -> ActionLogRefusal? in
            guard case .refusal(let refusal) = entry else { return nil }
            return refusal
        }
        #expect(refusals.map(\.code) == [.invalidArgument, .paused])
        #expect(refusals.allSatisfy { $0.tool == .keyboard && $0.operationID == OperationID("op-1") })
    }
}
