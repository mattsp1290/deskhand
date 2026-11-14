import DeskhandCore
import Testing

/// The action log around an effect (contract 11.3, 12.3, 12.10): every admitted call gets its
/// outcome entry, no append can hold the section or the answer for ever, and a caller hanging up
/// does not cancel an append.
@Suite("Executor: the action log")
struct ActionLogTests {
    static let shortWait: Duration = .milliseconds(100)

    @Test("a final record write that fails still gets an outcome entry: failed, with the events posted")
    func finalRecordWriteFails() async throws {
        let loader = FakeStoreLoader()
        // The load's replace crosses boundaries 0 to 3, admission 4 and 5, executing 6 and 7, and
        // the final record's append is 8.
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
        let harness = try Harness(waitLimit: Self.shortWait)
        let gate = Gate()
        await harness.onLog(.intent) { await gate.pass() }
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 3, "y": 4]))
        #expect(answer.code == .logUnavailable)
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
        let harness = try Harness(waitLimit: Self.shortWait)
        let gate = Gate()
        await harness.onLog(.outcome) { await gate.pass() }
        let answer = await harness.executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1]))
        #expect(answer.result?.eventsPosted == 1)
        #expect(harness.mac.read(\.logAppends) == [true, false])
        await gate.open()
    }

    @Test("a frame check that does not answer refuses with internal_error, and frees the section")
    func hungFrameCheck() async throws {
        let gate = Gate()
        let harness = try Harness(frames: FakeFrames(gate: gate), waitLimit: Self.shortWait)
        let answer = await harness.executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1]))
        #expect(answer.code == .internalError)
        #expect(harness.mac.posted.isEmpty)
        #expect(await harness.executor.isInSection == false)
        await gate.open()
    }

    @Test("a patch recapture that does not answer is stale_frame pixels_changed")
    func hungRecapture() async throws {
        let gate = Gate()
        let mac = FakeMac { $0.patchGate = gate }
        let harness = try Harness(mac: mac, waitLimit: Self.shortWait)
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 3, "y": 4]))
        #expect(answer.code == .staleFrame)
        #expect(answer.details == ["reason": "pixels_changed", "point_index": 0])
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
        let answer = await task.value
        #expect(answer.code == .cancelled)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 1))
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
        guard case .dropped = await task.value else {
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
