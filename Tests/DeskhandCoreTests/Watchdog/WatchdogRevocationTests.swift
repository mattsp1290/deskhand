import DeskhandCore
import Testing

/// Contract 13.1 and 14.4 with no file-change source: the periodic read alone notices that the
/// allowance file was removed and passes the revocation to the executor in time, wherever the
/// removal falls between two reads and however late the owner reaches the file.
@Suite("Watchdog: revocation by the periodic read", .timeLimit(.minutes(1)))
struct WatchdogRevocationTests {
    /// How late the owner reaches the file at the read before the removal and at those after it.
    struct Lateness: Sendable, CustomTestStringConvertible {
        let beforeMs: Int64
        let afterMs: Int64

        var testDescription: String { "owner late by \(beforeMs) ms before the removal, \(afterMs) ms after" }
    }

    static let lateness = [
        Lateness(beforeMs: 0, afterMs: 0), Lateness(beforeMs: 3, afterMs: 0), Lateness(beforeMs: 300, afterMs: 0),
        Lateness(beforeMs: 0, afterMs: 150), Lateness(beforeMs: 0, afterMs: 300), Lateness(beforeMs: 300, afterMs: 300),
    ]

    static let readMs = Int64(Watchdog.Configuration.maxAllowanceReadInterval / .milliseconds(1))

    /// What may pass between the removal and the interruption: the rest of `DEADLINE_BOUND_MS`
    /// covers the executor's next check, at most one `USER_ACTIVITY_POLL_MS` away, and the releases.
    static let interruptBudgetMs = Int64(ContractConstants.deadlineBoundMs - ContractConstants.userActivityPollMs)

    @Test("a removal anywhere between two reads reaches the executor within the bound", arguments: lateness)
    func worstCase(lateness: Lateness) async {
        let gap = await Self.gapAfterRead(lateness: lateness)
        #expect(gap <= Self.readMs, "the next read starts \(gap) ms after the last")
        let last = min(gap, Self.readMs)
        var worst: Int64 = 0
        for offset in Array(stride(from: 1, to: last, by: 7)) + [last] where !Task.isCancelled {
            guard let latency = await Self.latency(removedAfterReadMs: offset, lateness: lateness) else {
                Issue.record("removed \(offset) ms after a read: never stopped")
                return
            }
            worst = max(worst, latency)
        }
        #expect(worst <= Self.readMs + lateness.afterMs, "worst \(worst) ms")
        #expect(worst <= Self.interruptBudgetMs, "worst \(worst) ms")
    }

    @Test("with no file-change source, and a longer read interval asked for, run() reads every 500 ms")
    func runWithoutSources() async {
        #expect(Watchdog.Configuration().allowanceReadInterval == .milliseconds(Self.readMs))
        let clock = ManualScheduler()
        let desk = CacheDesk(clock: clock)
        let executor = FakeExecutor(clock: clock)
        let watchdog = Watchdog(
            owner: desk, executor: executor, activity: StaticActivity(), scheduler: clock,
            configuration: .init(allowanceReadInterval: .seconds(10)))
        let running = Task { await watchdog.run() }
        await clock.waitUntil { $0.contains(WatchdogFixture.at(Self.readMs).monotonic) }
        clock.advance(byMilliseconds: 10)
        desk.removeFile()
        clock.advance(to: WatchdogFixture.at(Self.readMs).monotonic)
        await executor.waitForInterrupts(1)
        #expect(await executor.firstInterrupt { $0 == .state(.gated) } == Self.readMs)
        running.cancel()
        _ = await finished(running)
    }

    /// Runs a fresh watchdog to its second read, the first periodic one.
    static func toSecondRead(lateness: Lateness) async -> (
        CacheDesk, FakeExecutor, Watchdog, readAt: Int64, wakeup: ContinuousClock.Instant?
    ) {
        let clock = ManualScheduler()
        let desk = CacheDesk(clock: clock)
        let executor = FakeExecutor(clock: clock)
        let watchdog = Watchdog(owner: desk, executor: executor, activity: StaticActivity(), scheduler: clock)
        desk.setLate(lateness.beforeMs)
        var wakeup = await watchdog.evaluate()
        while desk.world.withLock(\.reductions.count) < 2, let next = wakeup, !Task.isCancelled {
            clock.advance(to: max(next, clock.now))
            wakeup = await watchdog.evaluate()
        }
        return (desk, executor, watchdog, desk.world.withLock { $0.reductions.last ?? 0 }, wakeup)
    }

    /// How long after the second read the third one starts.
    static func gapAfterRead(lateness: Lateness) async -> Int64 {
        let (_, _, _, readAt, wakeup) = await toSecondRead(lateness: lateness)
        guard let wakeup else { return 0 }
        return WatchdogFixture.milliseconds(since: WatchdogFixture.at(readAt).monotonic, to: wakeup)
    }

    /// From the removal of the file `offset` ms after the second read to the `gated` interruption.
    static func latency(removedAfterReadMs offset: Int64, lateness: Lateness) async -> Int64? {
        let (desk, executor, watchdog, readAt, first) = await toSecondRead(lateness: lateness)
        let clock = desk.clock
        clock.advance(to: WatchdogFixture.at(readAt + offset).monotonic)
        desk.removeFile()
        desk.setLate(lateness.afterMs)
        var wakeup = first
        while await executor.interrupts.isEmpty, let next = wakeup, clock.elapsedMs < readAt + 10_000, !Task.isCancelled
        {
            clock.advance(to: max(next, clock.now))
            wakeup = await watchdog.evaluate()
        }
        return await executor.firstInterrupt { $0 == .state(.gated) }.map { $0 - (readAt + offset) }
    }
}
