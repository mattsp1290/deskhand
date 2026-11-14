import DeskhandCore
import Synchronization
import Testing

/// What a clean stop did, in order, across the host, the executor and the exit.
final class StopTrace: Sendable {
    enum Step: Hashable, Sendable {
        case stopAccepting
        case executorStop
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

struct RecordingStopHost: CleanStopHost {
    let trace: StopTrace

    func stopAcceptingCalls() async { trace.record(.stopAccepting) }
    func dropLeaseAndFrames() async { trace.record(.dropLease) }
    func logStop(_ report: CleanStopReport) { trace.record(.log(report)) }
    func closeConnections() async { trace.record(.close) }
}

/// An executor whose stop answers `answer`, after `gate` opens when there is one.
actor FakeStoppableExecutor: StoppableExecutor {
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

/// The process stop (contract 15.2): one deadline of `DEADLINE_BOUND_MS` for every wait, the steps
/// in order, one exit with status 0.
@Suite("Stop: the clean stop")
struct CleanStopTests {
    static func cleanStop(
        _ executor: any StoppableExecutor, trace: StopTrace, scheduler: ManualScheduler
    ) -> CleanStop {
        CleanStop(
            executor: executor, host: RecordingStopHost(trace: trace), scheduler: scheduler,
            exit: { trace.record(.exit($0)) })
    }

    @Test("an idle stop runs every step in order and exits 0 at once")
    func idleStop() async {
        let trace = StopTrace()
        let scheduler = ManualScheduler()
        let executor = FakeStoppableExecutor(trace: trace)

        let report = await Self.cleanStop(executor, trace: trace, scheduler: scheduler).stop()

        let expected = CleanStopReport(
            executor: ExecutorStop(operation: nil, heldInput: []), leaseDropped: true, elapsed: .zero)
        #expect(report == expected)
        #expect(trace.steps == [.stopAccepting, .executorStop, .dropLease, .log(expected), .close, .exit(0)])
    }

    @Test("an executor that has not answered by the bound is left behind, and the process exits 0 at it")
    func executorPastTheBound() async {
        let trace = StopTrace()
        let scheduler = ManualScheduler()
        let gate = Gate.opening(after: .seconds(30))
        let executor = FakeStoppableExecutor(trace: trace, gate: gate)
        let stop = Self.cleanStop(executor, trace: trace, scheduler: scheduler)

        let running = Task { await stop.stop() }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        await scheduler.waitForSleepers(1)
        scheduler.advance(byMilliseconds: Int64(ContractConstants.deadlineBoundMs) - 1)
        #expect(trace.exits.isEmpty)
        scheduler.advance(byMilliseconds: 1)
        let report = await running.value

        let expected = CleanStopReport(executor: nil, leaseDropped: false, elapsed: .seconds(1))
        #expect(report == expected)
        #expect(trace.steps == [.stopAccepting, .executorStop, .log(expected), .exit(0)])
    }

    @Test("a second stop while the first runs waits for it, changes nothing, and the process exits once")
    func secondStopIsHarmless() async {
        let trace = StopTrace()
        let scheduler = ManualScheduler()
        let gate = Gate.opening(after: .seconds(30))
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
        "SIGTERM mid-operation: aborted_by_restart with the exact count, input released or kept owed, lease dropped, logged, exit 0 within the bound",
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
                operation: StoppedOperation(
                    key: call.key, outcome: .abortedByRestart(eventsPosted: 2), recorded: true, logged: true),
                heldInput: held),
            leaseDropped: true, elapsed: .zero)
        #expect(report == expected)
        #expect(trace.steps == [.stopAccepting, .dropLease, .log(expected), .close, .exit(0)])
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
