import DeskhandCore
import Testing

@Suite("Watchdog: deadline and revocation", .timeLimit(.minutes(1)))
struct WatchdogDeadlineTests {
    struct Sources: CustomTestStringConvertible, Sendable {
        let armedMs: Int64
        let allowanceMs: Int64?
        let leaseTTLMs: Int?
        let deadlineMs: Int64?

        var testDescription: String {
            "armed \(armedMs), allowance \(allowanceMs.map(String.init) ?? "-"), "
                + "lease \(leaseTTLMs.map(String.init) ?? "-")"
        }
    }

    static let sources: [Sources] = [
        Sources(armedMs: 5000, allowanceMs: 600_000, leaseTTLMs: nil, deadlineMs: 5000),
        Sources(armedMs: 3_600_000, allowanceMs: 7000, leaseTTLMs: nil, deadlineMs: 7000),
        Sources(armedMs: 3_600_000, allowanceMs: 600_000, leaseTTLMs: 9000, deadlineMs: 9000),
        Sources(armedMs: 8000, allowanceMs: 6000, leaseTTLMs: 7000, deadlineMs: 6000),
        Sources(armedMs: 6000, allowanceMs: 8000, leaseTTLMs: 7000, deadlineMs: 6000),
        Sources(armedMs: 8000, allowanceMs: 7000, leaseTTLMs: 6000, deadlineMs: 6000),
    ]

    @Test("the deadline is the earliest of the allowance, the lease and arming", arguments: sources)
    func deadline(sources: Sources) {
        let desk = FakeDesk(
            clock: ManualScheduler(), armedMs: sources.armedMs, allowanceMs: sources.allowanceMs,
            leaseTTLMs: sources.leaseTTLMs)
        #expect(Watchdog.deadline(of: desk.snapshot()) == sources.deadlineMs.map { WatchdogFixture.at($0).monotonic })
    }

    @Test("nothing can end with no allowance and no lease")
    func noDeadline() {
        let desk = FakeDesk(clock: ManualScheduler(), allowanceMs: nil)
        desk.change { world in
            world.report =
                StateReducer.reduce(
                    previous: world.report, signals: world.signals, command: .disarm, now: WatchdogFixture.t0
                ).report
        }
        #expect(Watchdog.deadline(of: desk.snapshot()) == nil)
    }

    @Test("effects no reduction returned put the deadline at the reading", arguments: [nil, 30_000])
    func unreducedEffects(leaseTTLMs: Int?) {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, leaseTTLMs: leaseTTLMs)
        clock.advance(byMilliseconds: 250)
        var snapshot = desk.snapshot()
        #expect(Watchdog.deadline(of: snapshot) != snapshot.reading.monotonic)
        snapshot.hasUnreducedEffects = true
        #expect(Watchdog.deadline(of: snapshot) == WatchdogFixture.at(250).monotonic)
    }

    @Test("a lease held after arming ran out puts the deadline in the past")
    func pastDeadline() {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, armedMs: 1000, leaseTTLMs: 30_000)
        clock.advance(byMilliseconds: 2000)
        #expect(Watchdog.deadline(of: desk.snapshot()) == WatchdogFixture.at(1000).monotonic)
        #expect(Watchdog.interruptions(at: desk.snapshot()) == [.state(.disarmed)])
    }

    @Test("a renewal moves the deadline the watchdog wakes for")
    func renewalMovesTheWakeup() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, leaseTTLMs: 10_250)
        let executor = FakeExecutor(clock: clock)
        let watchdog = Watchdog(owner: desk, executor: executor, activity: StaticActivity(), scheduler: clock)
        var woke = await Self.step(watchdog, clock: clock, until: 5000)
        #expect(woke.last == 5000)

        desk.renewLease(ttlMs: 30_100)
        await watchdog.refreshState()
        woke = await Self.step(watchdog, clock: clock, until: 36_000)
        #expect(!woke.contains(10_250))
        #expect(woke.contains(35_100))
        let ended = await executor.firstInterrupt { if case .leaseEnded = $0 { true } else { false } }
        #expect(ended == 35_100)
        #expect(await executor.interrupts.allSatisfy { $0.1 >= 35_100 })
    }

    static func step(_ watchdog: Watchdog, clock: ManualScheduler, until endMs: Int64) async -> [Int64] {
        var woke: [Int64] = []
        var wakeup = await watchdog.evaluate()
        while let next = wakeup, next <= WatchdogFixture.at(endMs).monotonic, !Task.isCancelled {
            clock.advance(to: next)
            woke.append(clock.elapsedMs)
            wakeup = await watchdog.evaluate()
        }
        return woke
    }

    enum Ending: String, CaseIterable, Sendable {
        case arming, allowance, lease
    }

    @Test(
        "while idle the watchdog wakes at the deadline, has the owner reduce, and stops the effect",
        arguments: Ending.allCases)
    func idleTimer(ending: Ending) async {
        let clock = ManualScheduler()
        let desk = FakeDesk(
            clock: clock, armedMs: ending == .arming ? 4500 : 3_600_000,
            allowanceMs: ending == .allowance ? 4500 : 600_000, leaseTTLMs: ending == .lease ? 4500 : 60_000)
        let executor = FakeExecutor(clock: clock)
        let watchdog = Watchdog(owner: desk, executor: executor, activity: StaticActivity(), scheduler: clock)

        var wakeups: [Int64] = []
        var wakeup = await watchdog.evaluate()
        while let next = wakeup, clock.elapsedMs < 4500, !Task.isCancelled {
            clock.advance(to: next)
            wakeups.append(clock.elapsedMs)
            wakeup = await watchdog.evaluate()
        }
        #expect(wakeups.last == 4500, "woke at \(wakeups)")
        #expect(wakeups.allSatisfy { $0 <= 4500 })

        let stopped = await executor.firstInterrupt { interruption in
            switch (ending, interruption) {
            case (.arming, .state(.disarmed)), (.allowance, .state(.gated)): true
            case (.lease, .leaseEnded(let end)): end.cause == .expired
            default: false
            }
        }
        #expect(stopped == 4500)
        #expect(desk.read { $0.reductions.map(\.0) }.contains(WatchdogFixture.at(4500).monotonic))
        #expect(await executor.cleanupRetries.contains(4500))
        if ending != .lease {
            #expect(desk.read { $0.leases.lease } == .none, "the lease was not dropped")
        }
    }

    @Test("a removed allowance file stops the effect at the next poll, within 1 s of the change")
    func revocationByPoll() async throws {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, leaseTTLMs: 60_000)
        let executor = FakeExecutor(clock: clock)
        let signatures = FakeSignatures()
        signatures.set("/etc/deskhand", inode: 1)
        signatures.set("/etc/deskhand/allowance.json", inode: 2)
        let poll = PollingFileChangeSource(
            paths: ["/etc/deskhand", "/etc/deskhand/allowance.json"], interval: .milliseconds(250), scheduler: clock,
            signature: signatures.signature)
        let watchdog = Watchdog(
            owner: desk, executor: executor, activity: StaticActivity(), fileChanges: [poll], scheduler: clock)
        let running = Task { await watchdog.run() }
        await clock.waitUntil { $0.contains(WatchdogFixture.at(250).monotonic) }

        clock.advance(byMilliseconds: 200)
        signatures.set("/etc/deskhand/allowance.json", inode: nil)
        desk.change { $0.allowanceFile = .missing }
        clock.advance(to: WatchdogFixture.at(250).monotonic)
        await executor.waitForInterrupts(1)

        let stopped = await executor.firstInterrupt { $0 == .state(.gated) }
        #expect(stopped == 250)
        #expect(try #require(stopped) - 200 <= Int64(ContractConstants.deadlineBoundMs))
        #expect(desk.read { $0.reductions.last.map { $0.1 } } == true, "the poll did not bypass the copy")
        running.cancel()
        _ = await finished(running)
    }

    @Test("a watch event stops the effect at once")
    func revocationByWatch() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, leaseTTLMs: 60_000)
        let executor = FakeExecutor(clock: clock)
        let watch = FakeFileWatch()
        let watchdog = Watchdog(
            owner: desk, executor: executor, activity: StaticActivity(), fileChanges: [watch], scheduler: clock)
        let running = Task { await watchdog.run() }
        await watch.waitUntilWatched()
        await clock.waitForSleepers(1)

        clock.advance(byMilliseconds: 200)
        desk.change { $0.allowanceFile = .missing }
        watch.fire()
        await executor.waitForInterrupts(1)
        #expect(await executor.firstInterrupt { $0 == .state(.gated) } == 200)
        #expect(desk.read { $0.leases.lease } == .none)
        running.cancel()
        _ = await finished(running)
    }

    @Test("a valid replacement only moves the deadline")
    func validReplacement() async {
        let clock = ManualScheduler()
        let desk = FakeDesk(clock: clock, allowanceMs: 10_000)
        let executor = FakeExecutor(clock: clock)
        let watchdog = Watchdog(owner: desk, executor: executor, activity: StaticActivity(), scheduler: clock)
        _ = await watchdog.evaluate()
        #expect(Watchdog.deadline(of: desk.snapshot()) == WatchdogFixture.at(10_000).monotonic)
        clock.advance(byMilliseconds: 1000)
        desk.change { $0.allowanceFile = .valid(expiresAt: WatchdogFixture.at(4000).wall) }
        await watchdog.allowanceFileDidChange()
        #expect(Watchdog.deadline(of: desk.snapshot()) == WatchdogFixture.at(4000).monotonic)
        let woke = await Self.step(watchdog, clock: clock, until: 4000)
        #expect(woke.last == 4000)
        #expect(await executor.interrupts.map(\.1) == [4000])
        #expect(await executor.interruptions == [.state(.gated)])
    }
}

struct StaticActivity: UserActivitySource {
    var idleMs: Int? = 60_000

    func idleMilliseconds() -> Int? { idleMs }
}
