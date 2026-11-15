import Synchronization
import Testing

@testable import DeskhandCore

@Suite("Stop at the final event", .timeLimit(.minutes(1)))
struct FinalEventStopTests {
    @Test func finalEventStillExecutingIsInterrupted() async throws {
        let mac = FakeMac()
        let observer = FinalEventStopObserver(mac: mac)
        let harness = try Harness(mac: mac, overrides: .init(observer: observer))
        observer.stopAfterFinalPost(harness.executor)
        let gate = Gate()
        await harness.onLog(.outcome) { await gate.pass() }
        let call = try harness.keyboard(["type": "type", "text": "x"])
        let pending = Task { await harness.executor.perform(call) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()

        #expect(await harness.executor.isStopping)
        let stop = await harness.executor.stop()
        #expect(
            stop.operation
                == StoppedOperation(key: call.key, outcome: .abortedByRestart(eventsPosted: 2), recorded: true))
        #expect(stop.heldInput == .known([]))
        let events: [InputEvent] = [
            .keyDown(ExecutorFixture.carrier, text: "x"), .keyUp(ExecutorFixture.carrier, text: "x"),
        ]
        #expect(mac.posted == events)
        #expect(mac.released.isEmpty)
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(try await harness.status() == .found(OperationView(status: .abortedByRestart, eventsPosted: 2)))
        #expect(await harness.logEntries.map(\.kind) == [.intent])
        let entries = Task { await harness.executor.awaitStopEntries() }
        while await harness.executor.stopWaiters.isEmpty { await Task.yield() }
        await gate.open()
        #expect(await pending.value.structuredContent == nil)
        #expect(await entries.value == true)
        await EffectAnswerStopTests.settled(harness.executor)

        let logged = await harness.logEntries
        #expect(logged.map(\.kind) == [.intent, .outcome])
        guard case .intent(let intent)? = logged.first, case .outcome(let outcome)? = logged.last else {
            Issue.record("The admitted operation must have one intent and one outcome.")
            return
        }
        #expect(outcome.outcome == .abortedByRestart(eventsPosted: 2))
        #expect(outcome.intentTime == intent.time)
        #expect(outcome.principal == intent.principal)
        #expect(outcome.holderID == intent.holderID)
        #expect(outcome.operationID == call.arguments.operationID)
        #expect(outcome.operationID == intent.operationID)
        #expect(outcome.frameID == intent.frameID)
        #expect(outcome.frameSHA256 == intent.frameSHA256)
        #expect(outcome.action == intent.action)

        let restarted = try ExecutorStopTests.restarted(harness)
        #expect(try await restarted.status() == .found(OperationView(status: .abortedByRestart, eventsPosted: 2)))
        let replay = await restarted.executor.perform(call)
        #expect(replay.structuredContent?["code"] == "interrupted")
        #expect(replay.structuredContent?["operation"]?["status"] == "aborted_by_restart")
        #expect(replay.structuredContent?["operation"]?["events_posted"] == 2)
        #expect(mac.posted == events)
        #expect(mac.released.isEmpty)
    }
}

private final class FinalEventStopObserver: ExecutorObserver {
    let mac: FakeMac
    private let executor = Mutex<InputExecutor?>(nil)

    init(mac: FakeMac) { self.mac = mac }

    func stopAfterFinalPost(_ executor: InputExecutor) { self.executor.withLock { $0 = executor } }

    func didPostEvent(at instant: ContinuousClock.Instant) {
        mac.didPostEvent(at: instant)
        guard mac.posted.count == 2 else { return }
        let executor = executor.withLock { value in
            defer { value = nil }
            return value
        }
        executor?.assumeIsolated { executor in
            guard case .executing(_, _, eventsPosted: 2) = executor.section else {
                Issue.record("The final posted event must still belong to an executing operation.")
                return
            }
            executor.beginStop()
        }
    }

    func executionDidChange(executing: Bool) { mac.executionDidChange(executing: executing) }
    func actionLogDidAppend(succeeded: Bool) { mac.actionLogDidAppend(succeeded: succeeded) }
    func cleanupPendingDidChange(_ pending: Bool) { mac.cleanupPendingDidChange(pending) }
}
