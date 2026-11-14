import DeskhandCore
import Synchronization
import Testing

/// Starts one stop from inside a seam the executor awaits, and returns once the executor has taken
/// it, so the next check of the call in the section sees it. Later starts do nothing.
final class StopStarter: Sendable {
    private let task = Mutex<Task<ExecutorStop, Never>?>(nil)
    let executor: InputExecutor

    init(_ executor: InputExecutor) { self.executor = executor }

    func start() async {
        let executor = executor
        let started = task.withLock { task -> Bool in
            guard task == nil else { return false }
            task = Task { await executor.stop() }
            return true
        }
        guard started else { return }
        while !(await executor.isStopping) { await Task.yield() }
    }

    var stop: ExecutorStop? {
        get async { await task.withLock { $0 }?.value }
    }
}

/// The executor's part of a process stop (contract 15.2): the call in flight ends with the restart
/// statuses and an exact count, its input is released or stays owed, and no later call runs.
@Suite("Stop: the executor")
struct ExecutorStopTests {
    static let shiftK: JSONValue = ["type": "press", "key": "k", "modifiers": ["shift"], "hold_ms": 500]

    static func lock(_ mac: FakeMac) {
        let locked = ExecutorFixture.report([.locked], at: mac.reading)
        mac.change { $0.report = locked }
    }

    /// The executor a restart would build over the same disks.
    static func restarted(_ harness: Harness) throws -> Harness {
        try Harness(mac: harness.mac, frames: harness.frames, loader: harness.loader)
    }

    @Test("a stop during a hold ends it aborted_by_restart with the exact count, released and logged")
    func stopDuringHold() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let starter = StopStarter(harness.executor)
        mac.change { $0.onSleep = { await starter.start() } }
        let call = try harness.keyboard(Self.shiftK)

        let answer = await harness.executor.perform(call)

        #expect(answer.structuredContent == nil)
        let stop = try #require(await starter.stop)
        let key = call.key
        #expect(
            stop.operation
                == StoppedOperation(key: key, outcome: .abortedByRestart(eventsPosted: 2), recorded: true, logged: true)
        )
        #expect(stop.heldInput.isEmpty)
        #expect(mac.released == [.named(.k), .modifierKey(.shift)])
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(mac.read(\.sleeps).count == 1)
        #expect(try await harness.status() == .found(OperationView(status: .abortedByRestart, eventsPosted: 2)))
        let entries = await harness.logEntries
        #expect(entries.map(\.kind) == [.intent, .outcome])
        guard case .outcome(let outcome)? = entries.last else { return }
        #expect(outcome.outcome == .abortedByRestart(eventsPosted: 2))

        let next = try Self.restarted(harness)
        #expect(try await next.status() == .found(OperationView(status: .abortedByRestart, eventsPosted: 2)))
        let repeated = await next.executor.perform(call)
        #expect(repeated.structuredContent?["code"] == "interrupted")
        #expect(repeated.structuredContent?["operation"]?["status"] == "aborted_by_restart")
        #expect(repeated.structuredContent?["operation"]?["events_posted"] == 2)
        #expect(mac.posted.count == 2)
    }

    @Test("a stop while the screen is locked posts no release: the ledger keeps the input for the next start")
    func stopWhileLockedDefers() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let starter = StopStarter(harness.executor)
        mac.change {
            $0.onSleep = {
                Self.lock(mac)
                await starter.start()
            }
        }

        _ = await harness.executor.perform(try harness.keyboard(Self.shiftK))

        let stop = try #require(await starter.stop)
        #expect(stop.operation?.outcome == .abortedByRestart(eventsPosted: 2))
        #expect(stop.operation?.recorded == true)
        #expect(stop.heldInput == [.modifierKey(.shift), .named(.k)])
        #expect(mac.released.isEmpty)
        #expect(mac.ledgerOnDisk == [.modifierKey(.shift), .named(.k)])
        #expect(try await harness.status() == .found(OperationView(status: .abortedByRestart, eventsPosted: 2)))

        let next = try Self.restarted(harness)
        #expect(await next.executor.owesReleases)
    }

    @Test("a call admitted but not yet executing ends failed_before_execution with nothing posted")
    func stopBeforeExecution() async throws {
        let harness = try Harness()
        let starter = StopStarter(harness.executor)
        await harness.onLog(.intent) { await starter.start() }
        let call = try harness.keyboard(["type": "type", "text": "hi"])

        let answer = await harness.executor.perform(call)

        #expect(answer.structuredContent == nil)
        let stop = try #require(await starter.stop)
        #expect(
            stop.operation
                == StoppedOperation(key: call.key, outcome: .failedBeforeExecution, recorded: true, logged: true))
        #expect(harness.mac.posted.isEmpty)
        let entries = await harness.logEntries
        #expect(entries.map(\.kind) == [.intent, .outcome])
        guard case .outcome(let outcome)? = entries.last else { return }
        #expect(outcome.outcome == .failedBeforeExecution)

        let next = try Self.restarted(harness)
        let repeated = await next.executor.perform(call)
        #expect(repeated.structuredContent?["code"] == "interrupted")
        #expect(repeated.structuredContent?["operation"]?["status"] == "failed_before_execution")
    }

    @Test("an idle stop returns at once, and every later call is dropped with no record")
    func idleStopDropsLaterCalls() async throws {
        let harness = try Harness()

        let stop = await harness.executor.stop()

        #expect(stop == ExecutorStop(operation: nil, heldInput: []))
        let answer = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "x"]))
        #expect(answer.structuredContent == nil)
        #expect(harness.mac.posted.isEmpty)
        #expect(await harness.logEntries.isEmpty)
        #expect(try await harness.status() == .notFound)
    }

    @Test("a stop posts the releases an earlier abort still owes, once cleanup is authorized")
    func stopReleasesOwedInput() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        mac.change {
            $0.onSleep = { Self.lock(mac) }
        }
        let aborted = await harness.executor.perform(try harness.keyboard(Self.shiftK))
        #expect(aborted.code == .locked)
        #expect(mac.ledgerOnDisk == [.modifierKey(.shift), .named(.k)])
        mac.change { $0.report = ExecutorFixture.okReport }

        let stop = await harness.executor.stop()

        #expect(stop == ExecutorStop(operation: nil, heldInput: []))
        #expect(mac.released == [.named(.k), .modifierKey(.shift)])
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("a stop waits for a refusal entry held back for a late intent, which is then written once, after it")
    func stopWaitsForHeldRefusal() async throws {
        let harness = try Harness(waitLimit: .milliseconds(100))
        let gate = Gate.opening(after: .seconds(3))
        await harness.onLog(.intent) { await gate.pass() }
        let answer = await harness.executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1]))
        #expect(answer.code == .logUnavailable)
        #expect(await harness.logEntries.isEmpty)

        let executor = harness.executor
        let returned = Mutex(false)
        let stopping = Task {
            let stop = await executor.stop()
            returned.withLock { $0 = true }
            return stop
        }
        while !(await executor.isStopping) { await Task.yield() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!returned.withLock { $0 }, "the stop returned while the refusal entry was still held back")

        await gate.open()
        let stop = await stopping.value
        #expect(stop == ExecutorStop(operation: nil, heldInput: []))
        let entries = await harness.logEntries
        #expect(entries.map(\.kind) == [.intent, .refusal])
        guard case .refusal(let refusal)? = entries.last else { return }
        #expect(refusal.code == .logUnavailable)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await harness.logEntries.count == 2, "the held refusal entry was written twice")
        #expect(harness.mac.posted.isEmpty)
    }

    @Test("a second stop during the first changes nothing and reports the same operation")
    func secondStopIsHarmless() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let starter = StopStarter(harness.executor)
        let executor = harness.executor
        let second = Mutex<Task<ExecutorStop, Never>?>(nil)
        mac.change {
            $0.onSleep = {
                await starter.start()
                second.withLock { $0 = Task { await executor.stop() } }
            }
        }

        _ = await harness.executor.perform(try harness.keyboard(Self.shiftK))

        let first = try #require(await starter.stop)
        let again = try #require(await second.withLock { $0 }?.value)
        #expect(again == first)
        #expect(await harness.executor.stop() == first)
        #expect(mac.released == [.named(.k), .modifierKey(.shift)])
        #expect(await harness.logEntries.map(\.kind) == [.intent, .outcome])
    }
}
