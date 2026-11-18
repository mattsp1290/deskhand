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

/// ``FakeClockScheduler``, recording the deadline of every sleep that is neither over nor
/// cancelled, so a test moves the clock only once both loops have gone to sleep. A cancelled timer
/// leaves at once, not at its next poll, so it never stands in for a loop that is awake.
private final class SleepRecordingScheduler: WatchdogScheduler {
    private let base: FakeClockScheduler
    private let sleeping = Mutex<(next: UInt64, deadlines: [UInt64: ContinuousClock.Instant])>((0, [:]))

    init(clock: ToolClock) { base = FakeClockScheduler(clock: clock) }

    var now: ContinuousClock.Instant { base.now }

    var deadlines: [ContinuousClock.Instant] { sleeping.withLock { $0.deadlines.values.sorted() } }

    func sleep(until deadline: ContinuousClock.Instant) async {
        let id = sleeping.withLock { sleeping in
            sleeping.next += 1
            sleeping.deadlines[sleeping.next] = deadline
            return sleeping.next
        }
        await withTaskCancellationHandler {
            await base.sleep(until: deadline)
        } onCancel: {
            _ = sleeping.withLock { $0.deadlines.removeValue(forKey: id) }
        }
        _ = sleeping.withLock { $0.deadlines.removeValue(forKey: id) }
    }
}

@Suite(.timeLimit(.minutes(1))) struct DeskOwnerWatchdogTests {
    /// Both loops wake at the allowance's end, and whichever snapshot comes first commits the
    /// lapse, so the owner's loop finds no passed deadline. It reduces at that wake all the same,
    /// not at the next periodic read of the allowance file, which the clock never reaches here.
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
        let scheduler = SleepRecordingScheduler(clock: clock)
        let watchdog = Watchdog(
            owner: desk, executor: IdleExecutor(), activity: NobodyAtTheMac(),
            scheduler: scheduler, configuration: Watchdog.Configuration(allowanceReadInterval: .milliseconds(500)))
        let run = Task { await watchdog.run() }
        let lapseAt = ToolFixture.t0.monotonic.advanced(by: .milliseconds(200))
        #expect(await eventually(timeout: .seconds(5)) { scheduler.deadlines == [lapseAt, lapseAt] })
        #expect(desk.reductions.count == 1)
        clock.advance(byMilliseconds: 250)
        #expect(await eventually(timeout: .seconds(5)) { desk.reductions.count >= 2 })
        run.cancel()
        await run.value

        let reductions = desk.reductions
        try #require(reductions.count == 2)
        let lapse = reductions[1]
        #expect(lapse.reading.monotonic == ToolFixture.t0.monotonic.advanced(by: .milliseconds(250)))
        #expect(lapse.effects.contains(.cancelInFlight(.gated)))
        #expect(lapse.leaseEnds.map(\.cause) == [.dropped(.gated)])
        #expect(owner.snapshot().hasUnreducedEffects == false)
    }
}
