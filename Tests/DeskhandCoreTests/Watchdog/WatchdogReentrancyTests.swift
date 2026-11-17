import DeskhandCore
import Synchronization
import Testing

@Suite("Watchdog: reductions and answers that take a while", .timeLimit(.minutes(1)))
struct WatchdogReentrancyTests {
    @Test("a file change that arrives during a reduction is read in one more pass")
    func changeDuringReduction() async {
        let clock = ManualScheduler()
        let owner = HeldReductionOwner(desk: FakeDesk(clock: clock, leaseTTLMs: 100))
        let watchdog = Watchdog(
            owner: owner, executor: FakeExecutor(clock: clock), activity: StaticActivity(), scheduler: clock)
        _ = await watchdog.evaluate()
        #expect(owner.calls == [true])

        clock.advance(byMilliseconds: 100)
        owner.holdNext()
        let evaluation = Task { await watchdog.evaluate() }
        await owner.waitUntilHeld()
        await watchdog.allowanceFileDidChange()
        #expect(owner.calls == [true, false])
        owner.release()
        _ = await finished(evaluation)
        #expect(owner.calls == [true, false, true], "the change was dropped")
    }

    @Test("an owner that tells the watchdog of a change from inside its reduction starts no other reduction")
    func refreshFromInsideTheReduction() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, leaseTTLMs: 60_000)
        let owner = RefreshingOwner(desk: desk)
        let watchdog = Watchdog(
            owner: owner, executor: FakeExecutor(clock: clock), activity: StaticActivity(), scheduler: clock)
        owner.watchdog.withLock { $0 = watchdog }
        #expect(await watchdog.evaluate() == WatchdogFixture.at(500).monotonic)
        #expect(desk.read(\.reductions.count) == 1, "the refresh from inside the reduction read the file again")
        clock.advance(byMilliseconds: 500)
        #expect(await watchdog.evaluate() == WatchdogFixture.at(1000).monotonic)
        #expect(desk.read(\.reductions.count) == 2)
    }

    @Test("a wake that arrives while the executor's loop is awake makes it evaluate again before it sleeps")
    func wakeDuringEvaluation() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock)
        let executor = HeldExecutor()
        let watchdog = Watchdog(owner: desk, executor: executor, activity: StaticActivity(), scheduler: clock)
        await executor.hold()
        let running = Task { await watchdog.run() }
        await executor.waitUntilHeld()
        await clock.waitUntil { $0 == [WatchdogFixture.at(500).monotonic] }
        desk.change { $0.allowanceFile = .valid(expiresAt: WatchdogFixture.at(300).wall) }
        await watchdog.allowanceFileDidChange()
        await executor.release()
        let deadline = WatchdogFixture.at(300).monotonic
        await clock.waitUntil { $0 == [deadline, deadline] }
        #expect(clock.sleeperDeadlines == [deadline, deadline])
        running.cancel()
        _ = await finished(running)
    }

    @Test("an executor that does not answer holds up no read of the allowance file")
    func busyExecutor() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, leaseTTLMs: 60_000)
        let executor = HeldExecutor()
        let watch = FakeFileWatch()
        let watchdog = Watchdog(
            owner: desk, executor: executor, activity: StaticActivity(), fileChanges: [watch], scheduler: clock)
        let running = Task { await watchdog.run() }
        await watch.waitUntilWatched()
        await desk.waitForReductions(1)
        await executor.hold()
        watch.fire()
        await executor.waitUntilHeld()
        await desk.waitForReductions(2)

        for read in 1...4 {
            await clock.waitUntil { $0.contains(WatchdogFixture.at(Int64(read) * 500).monotonic) }
            clock.advance(to: WatchdogFixture.at(Int64(read) * 500).monotonic)
            await desk.waitForReductions(2 + read)
        }
        desk.change { $0.allowanceFile = .missing }
        watch.fire()
        await desk.waitForReductions(7)
        #expect(desk.snapshot().state == .gated, "the executor would read an allowance that was removed")
        #expect(desk.read { $0.leases.lease } == .none)
        await executor.release()
        running.cancel()
        _ = await finished(running)
    }

    @Test("an owner that refreshes from inside its reduction holds up no read while the executor does not answer")
    func refreshInsideTheReductionWithABusyExecutor() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, leaseTTLMs: 60_000)
        let owner = RefreshingOwner(desk: desk)
        let executor = HeldExecutor()
        let watch = FakeFileWatch()
        let watchdog = Watchdog(
            owner: owner, executor: executor, activity: StaticActivity(), fileChanges: [watch], scheduler: clock)
        owner.watchdog.withLock { $0 = watchdog }
        let running = Task { await watchdog.run() }
        await watch.waitUntilWatched()
        await desk.waitForReductions(1)
        await executor.hold()

        watch.fire()
        await executor.waitUntilHeld()
        await desk.waitForReductions(2)

        for read in 1...4 {
            await clock.waitUntil { $0.contains(WatchdogFixture.at(Int64(read) * 500).monotonic) }
            clock.advance(to: WatchdogFixture.at(Int64(read) * 500).monotonic)
            await desk.waitForReductions(2 + read)
        }
        #expect(desk.read(\.reductions.count) >= 6, "the periodic read waited on the executor")
        desk.change { $0.allowanceFile = .missing }
        watch.fire()
        await desk.waitForReductions(7)
        #expect(desk.snapshot().state == .gated, "the executor would read an allowance that was removed")
        await executor.release()
        running.cancel()
        _ = await finished(running)
    }

    @Test("while a reduction another task started outlasts the read interval, the owner's loop does not spin")
    func noSpinWhileReducing() async {
        let clock = ManualScheduler()
        let owner = HeldReductionOwner(desk: FakeDesk(clock: clock))
        let watch = FakeFileWatch()
        let watchdog = Watchdog(
            owner: owner, executor: FakeExecutor(clock: clock), activity: StaticActivity(), fileChanges: [watch],
            scheduler: clock)
        let running = Task { await watchdog.run() }
        await watch.waitUntilWatched()
        await clock.waitUntil { $0.contains(WatchdogFixture.at(500).monotonic) }
        owner.holdNext()
        watch.fire()
        await owner.waitUntilHeld()

        clock.advance(to: WatchdogFixture.at(500).monotonic)
        await clock.waitUntil { $0.contains(WatchdogFixture.at(600).monotonic) }
        let snapshots = owner.snapshots
        clock.advance(to: WatchdogFixture.at(600).monotonic)
        await clock.waitUntil { $0.contains(WatchdogFixture.at(700).monotonic) }
        #expect(owner.snapshots - snapshots < 10, "\(owner.snapshots - snapshots) snapshots in 100 ms")
        #expect(owner.calls == [true, true])

        owner.release()
        await owner.waitForCalls(3)
        #expect(owner.calls == [true, true, true], "the read asked for during the reduction was not made")
        running.cancel()
        _ = await finished(running)
    }

    @Test("an owner that refreshes inside its reduction and leaves a passed deadline unsettled reduces once per retry")
    func noSpinOnAnUnsettledDeadline() async {
        let clock = ManualScheduler()
        let owner = UnsettlingOwner(desk: FakeDesk(clock: clock, leaseTTLMs: 100))
        let watchdog = Watchdog(
            owner: owner, executor: FakeExecutor(clock: clock), activity: StaticActivity(), scheduler: clock)
        owner.watchdog.withLock { $0 = watchdog }
        clock.advance(to: WatchdogFixture.at(200).monotonic)
        let running = Task { await watchdog.run() }

        // A spinning owner's loop never sleeps, so the wait for both loops to sleep at the retry
        // (the executor's loop sleeps at the same deadline wakeup) would only end at the time
        // limit; this many reductions ends it at once instead.
        let spinThreshold = 50
        for retry in 1...3 {
            let wakeup = WatchdogFixture.at(200 + Int64(retry) * 100).monotonic
            await Self.firstOf(
                { await clock.waitUntil { $0 == [wakeup, wakeup] } },
                { await owner.waitForReductions(retry + spinThreshold) })
            #expect(owner.reductions == retry, "\(owner.reductions) reductions before the clock reached \(wakeup)")
            clock.advance(to: wakeup)
        }
        running.cancel()
        _ = await finished(running)
    }

    @Test("a refresh inside a reduction that another task started wakes the owner's loop once it ends")
    func refreshInsideAnotherTasksReductionWakesTheOwnerLoop() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, leaseTTLMs: 60_000)
        let owner = UnsettlingOwner(desk: desk)
        let watchdog = Watchdog(
            owner: owner, executor: FakeExecutor(clock: clock), activity: StaticActivity(), scheduler: clock)
        owner.watchdog.withLock { $0 = watchdog }
        let running = Task { await watchdog.run() }
        let asleep = [WatchdogFixture.at(500).monotonic, WatchdogFixture.at(60_000).monotonic]
        await clock.waitUntil { $0.sorted() == asleep }
        let startup = owner.reductions

        // The lease now runs out at 100 ms, with neither loop told, so both sleep on past 150 ms.
        desk.renewLease(ttlMs: 100)
        clock.advance(to: WatchdogFixture.at(150).monotonic)
        await watchdog.executionDidChange(executing: false)

        let retry = WatchdogFixture.at(250).monotonic
        await clock.waitUntil { $0 == [retry, retry] }
        #expect(owner.reductions == startup + 2, "the evaluation's reduction, then the owner's loop's")
        running.cancel()
        _ = await finished(running)
    }

    private static func firstOf(
        _ first: @escaping @Sendable () async -> Void, _ second: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await first() }
            group.addTask { await second() }
            await group.next()
            group.cancelAll()
        }
    }
}

/// Never settles the lease that ran out, as an owner that fails to would, and tells the watchdog
/// of a change from inside every reduction.
final class UnsettlingOwner: WatchdogStateOwner {
    let desk: FakeDesk
    let watchdog = Mutex<Watchdog?>(nil)
    private let count = Mutex(0)
    private let reduced = Waiters()

    init(desk: FakeDesk) { self.desk = desk }

    var reductions: Int { count.withLock { $0 } }

    func waitForReductions(_ count: Int) async { await reduced.wait { self.reductions >= count } }

    func snapshot() -> DeskSnapshot { desk.snapshot() }

    func reduceNow(allowanceChanged: Bool) async {
        count.withLock { $0 += 1 }
        reduced.changed()
        await watchdog.withLock { $0 }?.refreshState()
    }
}

final class RefreshingOwner: WatchdogStateOwner {
    let desk: FakeDesk
    let watchdog = Mutex<Watchdog?>(nil)

    init(desk: FakeDesk) { self.desk = desk }

    func snapshot() -> DeskSnapshot { desk.snapshot() }

    func reduceNow(allowanceChanged: Bool) async {
        await desk.reduceNow(allowanceChanged: allowanceChanged)
        await watchdog.withLock { $0 }?.refreshState()
    }
}

final class HeldReductionOwner: WatchdogStateOwner {
    private struct State {
        var calls: [Bool] = []
        var snapshots = 0
        var holdNext = false
        var holding = false
    }

    let desk: FakeDesk
    private let state = Mutex(State())
    private let changes = Waiters()

    init(desk: FakeDesk) { self.desk = desk }

    var calls: [Bool] { state.withLock(\.calls) }

    var snapshots: Int { state.withLock(\.snapshots) }

    func holdNext() { state.withLock { $0.holdNext = true } }

    func waitUntilHeld() async { await changes.wait { self.state.withLock(\.holding) } }

    func waitForCalls(_ count: Int) async { await changes.wait { self.calls.count >= count } }

    func release() {
        state.withLock { $0.holding = false }
        changes.changed()
    }

    func snapshot() -> DeskSnapshot {
        state.withLock { $0.snapshots += 1 }
        return desk.snapshot()
    }

    func reduceNow(allowanceChanged: Bool) async {
        let hold = state.withLock { state in
            state.calls.append(allowanceChanged)
            defer { state.holdNext = false }
            state.holding = state.holding || state.holdNext
            return state.holdNext
        }
        changes.changed()
        if hold { await changes.wait { !self.state.withLock(\.holding) } }
        await desk.reduceNow(allowanceChanged: allowanceChanged)
    }
}

actor HeldExecutor: WatchdogExecutor {
    private nonisolated let state = Mutex((holding: false, held: 0))
    private nonisolated let changes = Waiters()

    var isExecuting: Bool { false }

    func hold() { state.withLock { $0.holding = true } }

    nonisolated func waitUntilHeld() async { await changes.wait { self.state.withLock { $0.held > 0 } } }

    func release() {
        state.withLock { $0 = (false, 0) }
        changes.changed()
    }

    func interrupt(_ interruption: Interruption) {}

    func retryCleanup(now: ClockReading) -> OwedRelease? { nil }

    func nextCleanupRetry(at now: ClockReading) async -> ContinuousClock.Instant? {
        let held = state.withLock { state in
            if state.holding { state.held += 1 }
            return state.holding
        }
        guard held else { return nil }
        changes.changed()
        await changes.wait { !self.state.withLock(\.holding) }
        return nil
    }
}
