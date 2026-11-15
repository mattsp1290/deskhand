import DeskhandCore
import Synchronization
import Testing

/// The admission section (contract 9.5): one call inside at a time, arrivals answered at once, and a
/// repeated `operation_id` performed once however close together the calls arrive.
@Suite("Executor: the admission section", .timeLimit(.minutes(1)))
struct ConcurrencyTests {
    @Test("while a call is being admitted: same key in progress or conflict, any other busy")
    func duringAdmission() async throws {
        let gate = Gate()
        let harness = try Harness(frames: FakeFrames(gate: gate))
        let executor = harness.executor
        let call = try harness.pointer(["type": "click", "x": 9, "y": 9])
        let first = Task { await executor.perform(call) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()

        let accepted = OperationView(status: .accepted, eventsPosted: 0)
        let same = await executor.perform(call)
        #expect(same.code == .operationInProgress)
        #expect(same.toolError?.operation == .existing(accepted))
        let changed = await executor.perform(try harness.pointer(["type": "click", "x": 10, "y": 9]))
        #expect(changed.code == .operationIDConflict)
        #expect(changed.operation == accepted)
        let other = await executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-2"))
        #expect(other.code == .busy)
        #expect(other.operation == nil)
        let stranger = await executor.perform(
            try harness.pointer(
                ["type": "move", "x": 1, "y": 1], principal: ExecutorFixture.otherPrincipal))
        #expect(stranger.code == .busy)
        #expect(try await harness.status() == .found(accepted))

        await gate.open()
        let answer = await finished(first)
        #expect(answer?.result?.eventsPosted == 3)
        guard case .replayed = await executor.perform(call) else {
            Issue.record("a repeat after the first call ended is not its replay")
            return
        }
        #expect(harness.mac.posted.count == 3)
    }

    @Test("while a call executes: same key in progress with its record, any other busy")
    func duringExecution() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        let call = try harness.keyboard(["type": "press", "key": "a", "hold_ms": 300])
        let other = try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-2")
        let answers = Mutex<[EffectAnswer]>([])
        mac.change {
            $0.onSleep = {
                guard answers.withLock({ $0.isEmpty }) else { return }
                let same = await executor.perform(call)
                let busy = await executor.perform(other)
                answers.withLock { $0 = [same, busy] }
            }
        }
        #expect(await executor.perform(call).result?.eventsPosted == 2)
        let seen = answers.withLock { $0 }
        #expect(seen.count == 2)
        #expect(seen.first?.code == .operationInProgress)
        #expect(seen.first?.toolError?.operation == .existing(OperationView(status: .executing, eventsPosted: 1)))
        #expect(seen.last?.code == .busy)
        #expect(mac.posted.count == 2)
    }

    @Test("two tasks racing with one operation_id post its events once", arguments: 0..<8)
    func racingRepeats(round: Int) async throws {
        let harness = try Harness()
        let executor = harness.executor
        let call = try harness.keyboard(["type": "type", "text": .string("race\(round)")])
        let answers = await withTaskGroup(of: EffectAnswer.self) { group in
            group.addTask { await executor.perform(call) }
            group.addTask { await executor.perform(call) }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let completed = answers.filter { $0.result != nil }
        #expect(completed.count == 1)
        for answer in answers where answer.result == nil {
            if case .replayed = answer { continue }
            #expect(answer.code == .operationInProgress)
        }
        #expect(harness.mac.posted.count == completed.first?.result?.eventsPosted)
        #expect(await harness.logEntries.filter { $0.kind == .intent }.count == 1)
    }
}
