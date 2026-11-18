import DeskhandCore
import Synchronization
import Testing

@testable import DeskhandServer

/// The watchdog's owner over a real ``DeskOwner``, which commits a lapse whenever a snapshot finds
/// it: the watchdog's own snapshots and the executor's alike.
private final class LapseOwner: WatchdogStateOwner {
    let owner: DeskOwner
    let signals: StateSignals
    private let recorded = Mutex<[DeskOwner.Reduction]>([])

    init(owner: DeskOwner, signals: StateSignals) {
        self.owner = owner
        self.signals = signals
    }

    var reductions: [DeskOwner.Reduction] { recorded.withLock { $0 } }

    func snapshot() -> DeskSnapshot { owner.snapshot() }

    func reduceNow(allowanceChanged: Bool) async {
        let reduction = owner.reduce(signals: signals)
        recorded.withLock { $0.append(reduction) }
    }
}

private actor IdleExecutor: WatchdogExecutor {
    var isExecuting: Bool { false }
    func interrupt(_ interruption: Interruption) {}
    func retryCleanup(now: ClockReading) -> OwedRelease? { nil }
    func nextCleanupRetry(at now: ClockReading) -> ContinuousClock.Instant? { nil }
}

private struct NobodyAtTheMac: UserActivitySource {
    func idleMilliseconds() -> Int? { 3_600_000 }
}

@Suite(.timeLimit(.minutes(1))) struct DeskOwnerWatchdogTests {
    /// The owner's loop wakes at the allowance's end, and its own snapshot commits the lapse, so
    /// no deadline shows as passed. It reduces at that wake all the same, not at the next periodic
    /// read of the allowance file, which the clock never reaches here.
    @Test func aLapseASnapshotCommitsIsReducedAtTheWakeThatFoundIt() async throws {
        let clock = ToolClock()
        let owner = DeskOwner(policy: ToolFixture.policy, displays: FakeDisplays(), clock: { clock.reading })
        var signals = ToolFixture.signals()
        signals.allowance = .valid(expiresAt: ToolFixture.t0.wall.adding(milliseconds: 200))
        owner.reduce(signals: signals, command: .arm(for: .seconds(3600)))
        _ = owner.applyLease(
            LeaseArguments(holderID: ToolFixture.holder, command: .acquire(ttlMs: 60_000)),
            principal: ToolFixture.principal)

        let desk = LapseOwner(owner: owner, signals: signals)
        let watchdog = Watchdog(
            owner: desk, executor: IdleExecutor(), activity: NobodyAtTheMac(),
            scheduler: FakeClockScheduler(clock: clock),
            configuration: Watchdog.Configuration(allowanceReadInterval: .milliseconds(500)))
        let run = Task { await watchdog.run() }
        #expect(await eventually(timeout: .seconds(5)) { desk.reductions.count == 1 })
        clock.advance(byMilliseconds: 250)
        #expect(await eventually(timeout: .seconds(5)) { desk.reductions.count >= 2 })
        run.cancel()
        await run.value

        let reductions = desk.reductions
        try #require(reductions.count == 2)
        let lapse = reductions[1]
        #expect(lapse.reading == clock.reading)
        #expect(lapse.effects.contains(.cancelInFlight(.gated)))
        #expect(lapse.leaseEnds.map(\.cause) == [.dropped(.gated)])
        #expect(owner.snapshot().hasUnreducedEffects == false)
    }
}
