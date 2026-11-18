import DeskhandCore
import Synchronization
import Testing

@Suite("Watchdog: effects a read committed and no reduction returned", .timeLimit(.minutes(1)))
struct WatchdogUnreducedEffectsTests {
    @Test("unreduced effects are reduced at once, with no deadline passed and no read due")
    func reducedAtOnce() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock)
        let owner = CommittingOwner(desk: desk)
        let watchdog = Watchdog(
            owner: owner, executor: FakeExecutor(clock: clock), activity: StaticActivity(), scheduler: clock)
        #expect(await watchdog.evaluate() == WatchdogFixture.at(500).monotonic)
        #expect(desk.read(\.reductions.count) == 1)

        clock.advance(byMilliseconds: 100)
        owner.commit()
        #expect(await watchdog.evaluate() == WatchdogFixture.at(500).monotonic)
        #expect(desk.read(\.reductions.count) == 2)
        #expect(desk.read(\.reductions.last?.1) == false, "the periodic read was not due")
    }

    @Test("effects a read commits after the reduction are reduced after the retry interval")
    func committedAfterTheReduction() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock)
        let owner = CommittingOwner(desk: desk)
        let watchdog = Watchdog(
            owner: owner, executor: FakeExecutor(clock: clock), activity: StaticActivity(), scheduler: clock)
        _ = await watchdog.evaluate()

        clock.advance(byMilliseconds: 100)
        owner.commit()
        owner.commitDuringNextReduction()
        #expect(await watchdog.evaluate() == WatchdogFixture.at(200).monotonic)
        #expect(desk.read(\.reductions.count) == 2)
    }
}

/// An owner that reports ``DeskSnapshot/hasUnreducedEffects`` from a lapse a read committed until
/// the next reduction, as the server's `DeskOwner` does.
final class CommittingOwner: WatchdogStateOwner {
    private struct State {
        var unreduced = false
        var commitDuringReduction = false
    }

    let desk: FakeDesk
    private let state = Mutex(State())

    init(desk: FakeDesk) { self.desk = desk }

    func commit() { state.withLock { $0.unreduced = true } }

    /// The next reduction leaves effects unreduced, as a read that commits another lapse right
    /// after it would.
    func commitDuringNextReduction() { state.withLock { $0.commitDuringReduction = true } }

    func snapshot() -> DeskSnapshot {
        var snapshot = desk.snapshot()
        snapshot.hasUnreducedEffects = state.withLock { $0.unreduced }
        return snapshot
    }

    func reduceNow(allowanceChanged: Bool) async {
        await desk.reduceNow(allowanceChanged: allowanceChanged)
        state.withLock { state in
            state.unreduced = state.commitDuringReduction
            state.commitDuringReduction = false
        }
    }
}
