import DeskhandCore
import Synchronization
import Testing

/// What a clean stop did, in order, across the host, the executor and the exit.
final class StopTrace: Sendable {
    enum Step: Hashable, Sendable {
        case beginStop
        case stopAccepting
        case executorStop
        case entries
        case dropLease
        case log(CleanStopReport)
        case close
        case exit(Int32)
    }

    private let recorded = Mutex<[Step]>([])

    var steps: [Step] { recorded.withLock { $0 } }

    func record(_ step: Step) { recorded.withLock { $0.append(step) } }

    var exits: [Int32] {
        steps.compactMap { step in
            guard case .exit(let status) = step else { return nil }
            return status
        }
    }
}

/// A host that records each step, and holds step 1 until `accepting` opens when there is one.
struct RecordingStopHost: CleanStopHost {
    let trace: StopTrace
    var accepting: Gate?

    func stopAcceptingCalls() async {
        trace.record(.stopAccepting)
        await accepting?.pass()
    }
    func dropLeaseAndFrames() async { trace.record(.dropLease) }
    func logStop(_ report: CleanStopReport) { trace.record(.log(report)) }
    func closeConnections() async { trace.record(.close) }
}

/// An executor whose stop answers `answer`, after `gate` opens when there is one.
actor FakeStoppableExecutor: StoppableExecutor {
    func beginStop() { trace.record(.beginStop) }

    func awaitStopEntries() -> Bool? {
        trace.record(.entries)
        return answer.operation.map { _ in true }
    }

    let trace: StopTrace
    let gate: Gate?
    let answer: ExecutorStop
    private(set) var calls = 0

    init(trace: StopTrace, gate: Gate? = nil, answer: ExecutorStop = ExecutorStop(operation: nil, heldInput: [])) {
        self.trace = trace
        self.gate = gate
        self.answer = answer
    }

    func stop() async -> ExecutorStop {
        calls += 1
        trace.record(.executorStop)
        await gate?.pass()
        return answer
    }
}

/// The process stop (contract 15.2): one deadline, ``CleanStop/margin`` short of
/// `DEADLINE_BOUND_MS` after the signal, for every wait; the executor marked stopping before step 1;
/// the steps in order; one exit with status 0.
@Suite("Stop: the clean stop", .timeLimit(.minutes(1)))
struct CleanStopTests {
    static let deadlineMs = Int64(ContractConstants.deadlineBoundMs) - Int64(CleanStop.defaultMargin / .milliseconds(1))

    static func cleanStop(
        _ executor: any StoppableExecutor, trace: StopTrace, scheduler: ManualScheduler, accepting: Gate? = nil
    ) -> CleanStop {
        CleanStop(
            executor: executor, host: RecordingStopHost(trace: trace, accepting: accepting), scheduler: scheduler,
            exit: { trace.record(.exit($0)) })
    }

    /// The executor is marked stopping before step 1, which runs alongside the executor's stop and
    /// ends before the connections close; the other steps are in `rest`'s order.
    static func expectSteps(_ trace: StopTrace, beginStop: Bool = true, then rest: [StopTrace.Step]) {
        let steps = trace.steps
        if beginStop { #expect(steps.first == .beginStop, "\(steps)") }
        #expect(steps.filter { $0 != .stopAccepting && $0 != .beginStop } == rest)
        let accepting = steps.firstIndex(of: .stopAccepting)
        #expect(accepting != nil, "step 1 never ran: \(steps)")
        if let accepting, let close = steps.firstIndex(of: .close) { #expect(accepting < close) }
    }

    @Test("an idle stop runs every step in order and exits 0 at once")
    func idleStop() async {
        let trace = StopTrace()
        let scheduler = ManualScheduler()
        let executor = FakeStoppableExecutor(trace: trace)

        let report = await Self.cleanStop(executor, trace: trace, scheduler: scheduler).stop()

        let expected = CleanStopReport(
            executor: ExecutorStop(operation: nil, heldInput: []), outcomeLogged: nil, leaseDropped: true,
            elapsed: .zero)
        #expect(report == expected)
        Self.expectSteps(trace, then: [.executorStop, .dropLease, .entries, .log(expected), .close, .exit(0)])
    }

    @Test(
        "an executor that has not answered is left behind, and the process exits 0 short of the bound after the signal")
    func executorPastTheBound() async {
        let trace = StopTrace()
        let scheduler = ManualScheduler()
        let gate = Gate()
        let executor = FakeStoppableExecutor(trace: trace, gate: gate)
        let stop = Self.cleanStop(executor, trace: trace, scheduler: scheduler)
        // The stop starts 300 ms after the signal arrived; the deadline runs from the signal.
        let signal = scheduler.now
        scheduler.advance(byMilliseconds: 300)

        let running = Task { await stop.stop(signalledAt: signal) }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        await scheduler.waitForSleepers(1)
        scheduler.advance(byMilliseconds: Self.deadlineMs - 300 - 1)
        #expect(trace.exits.isEmpty)
        scheduler.advance(byMilliseconds: 1)
        let report = await running.value

        let expected = CleanStopReport(
            executor: nil, outcomeLogged: nil, leaseDropped: false, elapsed: .milliseconds(Self.deadlineMs))
        #expect(report == expected)
        #expect(report.elapsed < .milliseconds(ContractConstants.deadlineBoundMs))
        let steps = trace.steps.filter { $0 != .stopAccepting }
        #expect(steps == [.beginStop, .executorStop, .log(expected), .exit(0)])
        await gate.open()
    }

    @Test(
        "a step 1 that hangs holds up neither the executor's stop nor the lease's drop, and the exit comes at the deadline"
    )
    func hungStepOne() async {
        let trace = StopTrace()
        let scheduler = ManualScheduler()
        let accepting = Gate()
        let executor = FakeStoppableExecutor(trace: trace)
        let stop = Self.cleanStop(executor, trace: trace, scheduler: scheduler, accepting: accepting)

        let running = Task { await stop.stop() }
        let expected = CleanStopReport(
            executor: ExecutorStop(operation: nil, heldInput: []), outcomeLogged: nil, leaseDropped: true,
            elapsed: .zero)
        while !trace.steps.contains(.log(expected)) { await Task.yield() }
        #expect(trace.exits.isEmpty)
        await scheduler.waitForSleepers(1)
        scheduler.advance(byMilliseconds: Self.deadlineMs)
        #expect(await running.value == expected)

        #expect(
            trace.steps.filter { $0 != .stopAccepting } == [
                .beginStop, .executorStop, .dropLease, .entries, .log(expected), .exit(0),
            ])
        #expect(trace.steps.contains(.stopAccepting))
        await accepting.open()
    }

    @Test("a second stop while the first runs waits for it, changes nothing, and the process exits once")
    func secondStopIsHarmless() async {
        let trace = StopTrace()
        let scheduler = ManualScheduler()
        let gate = Gate()
        let executor = FakeStoppableExecutor(trace: trace, gate: gate)
        let stop = Self.cleanStop(executor, trace: trace, scheduler: scheduler)

        let first = Task { await stop.stop() }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        let second = Task { await stop.stop() }
        await gate.open()

        let (one, two) = (await first.value, await second.value)
        #expect(one == two)
        #expect(await stop.stop() == one)
        #expect(await executor.calls == 1)
        #expect(trace.exits == [0])
    }

    @Test(
        "SIGTERM mid-operation: aborted_by_restart with the exact count, input released or kept owed, lease dropped, logged, exit 0",
        arguments: [false, true])
    func stopMidOperation(locked: Bool) async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let trace = StopTrace()
        let scheduler = ManualScheduler()
        let stop = Self.cleanStop(harness.executor, trace: trace, scheduler: scheduler)
        let running = Mutex<Task<CleanStopReport, Never>?>(nil)
        let executor = harness.executor
        mac.change {
            $0.onSleep = {
                if locked { ExecutorStopTests.lock(mac) }
                running.withLock { $0 = $0 ?? Task { await stop.stop() } }
                while !(await executor.isStopping) { await Task.yield() }
            }
        }
        let call = try harness.keyboard(ExecutorStopTests.shiftK)

        let answer = await harness.executor.perform(call)
        let report = try #require(await running.withLock { $0 }?.value)

        #expect(answer.structuredContent == nil)
        let held: [HeldInput] = locked ? [.modifierKey(.shift), .named(.k)] : []
        let expected = CleanStopReport(
            executor: ExecutorStop(
                operation: StoppedOperation(key: call.key, outcome: .abortedByRestart(eventsPosted: 2), recorded: true),
                heldInput: held),
            outcomeLogged: true, leaseDropped: true, elapsed: .zero)
        #expect(report == expected)
        Self.expectSteps(trace, beginStop: false, then: [.dropLease, .log(expected), .close, .exit(0)])
        #expect(mac.released == (locked ? [] : [.named(.k), .modifierKey(.shift)]))
        #expect(mac.ledgerOnDisk == held)
        #expect(try await harness.status() == .found(OperationView(status: .abortedByRestart, eventsPosted: 2)))
        guard case .outcome(let outcome)? = await harness.logEntries.last else {
            Issue.record("no outcome entry")
            return
        }
        #expect(outcome.outcome == .abortedByRestart(eventsPosted: 2))
    }
}
