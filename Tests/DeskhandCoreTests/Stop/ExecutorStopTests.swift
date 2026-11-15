import DeskhandCore
import DeskhandTestSupport
import Foundation
import Synchronization
import Testing

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
        while !(await executor.isStopping), !Task.isCancelled { await Task.yield() }
    }

    var stop: ExecutorStop? {
        get async {
            guard let task = task.withLock({ $0 }) else { return nil }
            return await finished(task)
        }
    }
}

func bounded<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T? {
    await finished(Task { await body() })
}

@Suite("Stop: the executor", .timeLimit(.minutes(1)))
struct ExecutorStopTests {
    static let shiftK: JSONValue = ["type": "press", "key": "k", "modifiers": ["shift"], "hold_ms": 500]

    static func lock(_ mac: FakeMac) {
        let locked = ExecutorFixture.report([.locked], at: mac.reading)
        mac.change { $0.report = locked }
    }

    static func restarted(_ harness: Harness) throws -> Harness {
        try Harness(mac: harness.mac, frames: harness.frames, loader: harness.loader)
    }

    @Test("a stop during a hold ends it aborted_by_restart with the exact count, released and logged")
    func stopDuringHold() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        let starter = StopStarter(executor)
        mac.change { $0.onSleep = { await starter.start() } }
        let call = try harness.keyboard(Self.shiftK)

        let answer = try #require(await bounded { await executor.perform(call) })

        #expect(answer.structuredContent == nil)
        let stop = try #require(await starter.stop)
        let key = call.key
        #expect(
            stop.operation == StoppedOperation(key: key, outcome: .abortedByRestart(eventsPosted: 2), recorded: true))
        #expect(await bounded { await executor.awaitStopEntries() } == true)
        #expect(stop.heldInput == .known([]))
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
        let executor = harness.executor
        let starter = StopStarter(executor)
        mac.change {
            $0.onSleep = {
                Self.lock(mac)
                await starter.start()
            }
        }
        let call = try harness.keyboard(Self.shiftK)

        _ = try #require(await bounded { await executor.perform(call) })

        let stop = try #require(await starter.stop)
        #expect(stop.operation?.outcome == .abortedByRestart(eventsPosted: 2))
        #expect(stop.operation?.recorded == true)
        #expect(stop.heldInput == .known([.modifierKey(.shift), .named(.k)]))
        #expect(mac.released.isEmpty)
        #expect(mac.ledgerOnDisk == [.modifierKey(.shift), .named(.k)])
        #expect(try await harness.status() == .found(OperationView(status: .abortedByRestart, eventsPosted: 2)))

        let next = try Self.restarted(harness)
        #expect(await next.executor.owesReleases)
    }

    @Test("a call admitted but not yet executing ends failed_before_execution with nothing posted")
    func stopBeforeExecution() async throws {
        let harness = try Harness()
        let executor = harness.executor
        let starter = StopStarter(executor)
        await harness.onLog(.intent) { await starter.start() }
        let call = try harness.keyboard(["type": "type", "text": "hi"])

        let answer = try #require(await bounded { await executor.perform(call) })

        #expect(answer.structuredContent == nil)
        let stop = try #require(await starter.stop)
        #expect(stop.operation == StoppedOperation(key: call.key, outcome: .failedBeforeExecution, recorded: true))
        #expect(await bounded { await executor.awaitStopEntries() } == true)
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
        let executor = harness.executor

        let stop = await bounded { await executor.stop() }

        #expect(stop == ExecutorStop(operation: nil, heldInput: .known([])))
        let call = try harness.keyboard(["type": "type", "text": "x"])
        let answer = try #require(await bounded { await executor.perform(call) })
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
        let executor = harness.executor

        let stop = await bounded { await executor.stop() }

        #expect(stop == ExecutorStop(operation: nil, heldInput: .known([])))
        #expect(mac.released == [.named(.k), .modifierKey(.shift)])
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test(
        "a stop returns once the record is written and the input released, while the outcome entry's append still waits"
    )
    func stopDoesNotWaitForTheOutcomeEntry() async throws {
        let mac = FakeMac()

        let harness = try Harness(mac: mac, waitTimer: ManualWaitLimits())
        let starter = StopStarter(harness.executor)
        let gate = Gate()
        mac.change { $0.onSleep = { await starter.start() } }
        await harness.onLog(.outcome) { await gate.pass() }
        let call = try harness.keyboard(Self.shiftK)
        let performing = Task { await harness.executor.perform(call) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()

        let stop = try #require(await starter.stop)
        #expect(
            stop.operation
                == StoppedOperation(key: call.key, outcome: .abortedByRestart(eventsPosted: 2), recorded: true))
        #expect(mac.released == [.named(.k), .modifierKey(.shift)])
        #expect(try await harness.status() == .found(OperationView(status: .abortedByRestart, eventsPosted: 2)))
        #expect(await harness.logEntries.map(\.kind) == [.intent])

        let executor = harness.executor
        let entries = Task { await executor.awaitStopEntries() }
        await gate.open()
        #expect(await finished(entries) == true)
        #expect(await harness.logEntries.map(\.kind) == [.intent, .outcome])
        let answer = try #require(await finished(performing))
        #expect(answer.structuredContent == nil)
    }

    @Test(
        "a stop returns while a refusal entry is held back for a late intent; the entries wait for it, written once, after it"
    )
    func entriesWaitForHeldRefusal() async throws {

        let limits = ManualWaitLimits()
        let harness = try Harness(waitTimer: limits)
        let gate = Gate()
        await harness.onLog(.intent) { await gate.pass() }
        let answer = try #require(
            await ActionLogTests.answer(
                of: try harness.pointer(["type": "move", "x": 1, "y": 1]), on: harness, after: gate, limits: limits))
        #expect(answer.code == .logUnavailable)
        #expect(await harness.logEntries.isEmpty)

        let executor = harness.executor
        #expect(await bounded { await executor.stop() } == ExecutorStop(operation: nil, heldInput: .known([])))
        let settled = Mutex(false)
        let entries = Task {
            let logged = await executor.awaitStopEntries()
            settled.withLock { $0 = true }
            return logged
        }

        for _ in 0..<1_000 { await Task.yield() }
        #expect(!settled.withLock { $0 }, "the entries settled while the refusal entry was still held back")

        await gate.open()
        let logged = try #require(await finished(entries), "the entries never settled")
        #expect(logged == nil)
        let written = await harness.logEntries
        #expect(written.map(\.kind) == [.intent, .refusal])
        guard case .refusal(let refusal)? = written.last else { return }
        #expect(refusal.code == .logUnavailable)
        let again = try #require(await bounded { await executor.awaitStopEntries() }, "the entries never settled")
        #expect(again == nil)
        #expect(await harness.logEntries.count == 2, "the held refusal entry was written twice")
        #expect(harness.mac.posted.isEmpty)
    }

    @Test("a second stop during the first changes nothing and reports the same operation")
    func secondStopIsHarmless() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        let starter = StopStarter(executor)
        let second = Mutex<Task<ExecutorStop, Never>?>(nil)
        mac.change {
            $0.onSleep = {
                await starter.start()
                second.withLock { $0 = Task { await executor.stop() } }
            }
        }

        let call = try harness.keyboard(Self.shiftK)
        _ = try #require(await bounded { await executor.perform(call) })

        let first = try #require(await starter.stop)
        let secondTask = try #require(second.withLock { $0 })
        let again = try #require(await finished(secondTask))
        #expect(again == first)
        #expect(await bounded { await executor.stop() } == first)
        #expect(mac.released == [.named(.k), .modifierKey(.shift)])
        #expect(await harness.logEntries.map(\.kind) == [.intent, .outcome])
    }

    @Test("a stop while the ledger cannot be read reports the held input as unknown, not as nothing held")
    func stopWithUnreadableLedger() async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveInLedger(UnreadableStoreTests.left)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.ledgerPath)
            let executor = await rig.start().executor
            rig.makeReady()

            let stop = try #require(await bounded { await executor.stop() })

            #expect(stop == ExecutorStop(operation: nil, heldInput: .unknown))
            #expect(stop.heldInput.mayBeHeld)
            #expect(rig.mac.released.isEmpty)
            let report = CleanStopReport(executor: stop, outcomeLogged: nil, leaseDropped: true, elapsed: .zero)
            #expect(report.description.contains("held input unknown"), "\(report)")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rig.ledgerPath)
            #expect(try rig.ledgerOnDisk() == UnreadableStoreTests.left)
        }
    }

    @Test("a stop once the ledger can be read again releases what it holds and reports nothing held")
    func stopAfterTheLedgerIsRepaired() async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveInLedger(UnreadableStoreTests.left)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.ledgerPath)
            let executor = await rig.start().executor
            rig.makeReady()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rig.ledgerPath)

            let stop = try #require(await bounded { await executor.stop() })

            #expect(stop == ExecutorStop(operation: nil, heldInput: .known([])))
            #expect(!stop.heldInput.mayBeHeld)
            #expect(rig.mac.released == UnreadableStoreTests.left.reversed())
            #expect(try rig.ledgerOnDisk().isEmpty)
        }
    }
}
