import DeskhandCore
import Synchronization
import Testing

/// The real executor built with the watchdog's activity source, and the watchdog driving its
/// cleanup retries (contract 11.2, 13.2).
@Suite("Watchdog: with the executor")
struct WatchdogExecutorTests {
    static let typing: JSONValue = ["type": "type", "text": "hello world"]
    static let drag: JSONValue = [
        "type": "drag", "path": [["x": 10, "y": 10], ["x": 200, "y": 10]], "duration_ms": 1000,
    ]

    @Test("recent input by the person refuses the call before admission with user_active")
    func recentActivityBeforeExecution() async throws {
        let watch = try ExecutorWatch(.personOnly)
        _ = watch.personActs(afterMilliseconds: 0)
        watch.mac.advance(byMilliseconds: 1200)
        let answer = await watch.executor.perform(try watch.call(Self.typing))
        #expect(answer.code == .userActive)
        #expect(answer.details == ["idle_ms": 1200])
        #expect(answer.operation == nil)
        #expect(watch.mac.posted.isEmpty)

        watch.mac.advance(byMilliseconds: 1800)
        #expect(await watch.executor.perform(try watch.call(Self.typing, operation: "op-2")).result != nil)
    }

    @Test("a signal that cannot be read or separated refuses the call with idle_ms 0")
    func inseparableBeforeExecution() async throws {
        let unreadable = try ExecutorWatch(.unavailable)
        let refused = await unreadable.executor.perform(try unreadable.call(Self.typing))
        #expect(refused.code == .userActive)
        #expect(refused.details == ["idle_ms": 0])

        // With a signal that counts deskhand's events, the posts of the last call are the latest input.
        let anyOrigin = try ExecutorWatch(.personOnly)
        #expect(await anyOrigin.executor.perform(try anyOrigin.call(["type": "move", "x": 5, "y": 5])).result != nil)
        anyOrigin.hid.setKind(.anyOrigin)
        anyOrigin.mac.advance(byMilliseconds: 500)
        let next = await anyOrigin.executor.perform(try anyOrigin.call(Self.typing, operation: "op-2"))
        #expect(next.code == .userActive)
        #expect(next.details == ["idle_ms": 0])
    }

    @Test("deskhand's own events do not stop typing, a drag or a chord")
    func ownPostsDoNotCount() async throws {
        for action in [Self.typing, Self.drag, ExecutionTests.chord] {
            let watch = try ExecutorWatch(.personOnly)
            let answer = await watch.executor.perform(try watch.call(action))
            #expect(answer.result != nil, "\(action): \(String(describing: answer.code))")
            #expect(watch.posts.recorder.lastPostedEvent != nil)
        }
    }

    @Test("the person typing over deskhand's typing stops it within 250 ms")
    func interventionDuringTyping() async throws {
        let mac = FakeMac()
        let watch = try ExecutorWatch(.personOnly, mac: mac)
        let touched = WatchdogTouch()
        let hid = watch.hid
        mac.change {
            $0.afterPost[3] = { world, now in
                world.offsetMs += 30
                let instant = now.instant(afterMilliseconds: 30)
                hid.personInput(at: instant)
                touched.mark(instant)
            }
        }
        let answer = await watch.executor.perform(try watch.call(Self.typing))
        #expect(answer.code == .userActive)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 3))
        #expect(mac.released == [.key(ExecutorFixture.carrier)])
        try Self.expectWithinAbortBound(since: touched, mac: mac)
    }

    @Test("the person moving the pointer during a drag stops it within 250 ms and drops the button")
    func interventionDuringDrag() async throws {
        let mac = FakeMac()
        let watch = try ExecutorWatch(.personOnly, mac: mac)
        let touched = Self.touchDuringSleep(3, watch)
        let answer = await watch.executor.perform(try watch.call(Self.drag))
        #expect(answer.code == .userActive)
        #expect(mac.released == [.button(.left)])
        #expect(mac.heldDown.isEmpty)
        try Self.expectWithinAbortBound(since: touched, mac: mac)
    }

    @Test("the person pressing a key during a held chord stops it within 250 ms and releases it")
    func interventionDuringChord() async throws {
        let mac = FakeMac()
        let watch = try ExecutorWatch(.personOnly, mac: mac)
        let touched = Self.touchDuringSleep(2, watch)
        let answer = await watch.executor.perform(try watch.call(ExecutionTests.chord))
        #expect(answer.code == .userActive)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 4))
        #expect(mac.released == ExecutionTests.chordReleases)
        try Self.expectWithinAbortBound(since: touched, mac: mac)
    }

    @Test("the watchdog retries owed releases on its wakeup and at once on a change of state")
    func cleanupRetries() async throws {
        let mac = FakeMac()
        try mac.leaveInLedger(RestartCleanupTests.leftOver)
        mac.setState([.locked])
        let watch = try ExecutorWatch(
            .personOnly, mac: mac, configuration: .init(allowanceReadInterval: .seconds(600)))
        let retry = mac.reading.monotonic.advanced(by: CleanupRetrySchedule.interval)
        #expect(await watch.watchdog.evaluate() == retry)
        #expect(mac.released.isEmpty)

        mac.advance(byMilliseconds: 400)
        #expect(await watch.watchdog.evaluate() == retry)
        mac.advance(byMilliseconds: 600)
        #expect(await watch.watchdog.evaluate() == retry.advanced(by: CleanupRetrySchedule.interval))
        #expect(mac.released.isEmpty)

        mac.advance(byMilliseconds: 10)
        mac.setState([])
        await watch.watchdog.refreshState()
        #expect(mac.released == RestartCleanupTests.leftOver.reversed())
        #expect(await watch.executor.nextCleanupRetry(at: mac.reading) == nil)
        #expect(await watch.watchdog.evaluate() == ExecutorFixture.t0.instant(afterMilliseconds: 30_000))
    }

    @Test("the end of an earlier lease, forwarded first, does not hide the person from a call under a later one")
    func staleLeaseEndHidesNothing() async throws {
        var current = ExecutorFixture.acquired()
        let release = LeaseArguments(holderID: ExecutorFixture.holder, command: .release)
        let acquire = LeaseArguments(holderID: ExecutorFixture.holder, command: .acquire(ttlMs: 30_000))
        _ = current.apply(release, principal: ExecutorFixture.principal, state: .ok, now: ExecutorFixture.t0)
        _ = current.apply(acquire, principal: ExecutorFixture.principal, state: .ok, now: ExecutorFixture.t0)
        guard case .held(let held) = current.lease else { throw WatchdogFakeFault() }
        let stale = ExecutorFixture.acquired(ttlMs: 1000, at: ExecutorFixture.t0.advanced(byMilliseconds: -5000))
        guard case .expired(let ended) = stale.state(at: ExecutorFixture.t0) else { throw WatchdogFakeFault() }
        #expect(ended.serial != held.serial)

        // The executor's own checks see nobody; only the watchdog's poll sees the person, after it
        // has forwarded the end of the lease its stale snapshot still shows.
        let mac = FakeMac()
        mac.change { $0.lease = current }
        let harness = try Harness(mac: mac)
        let watchdog = Watchdog(
            owner: StaleLeaseOwner(mac: mac, lease: stale), executor: harness.executor,
            activity: StaticActivity(idleMs: 7), scheduler: ManualScheduler())
        mac.change { $0.onSleep = { await watchdog.executionDidChange(executing: true) } }
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "hold_ms": 500]))
        #expect(answer.code == .userActive)
        #expect(answer.details == ["idle_ms": 7])
        #expect(mac.read(\.sleeps).count == 1)
    }

    /// The person touches the Mac 40 ms before the executor's `sleep`-th wait ends, so the check after
    /// that wait is the first to see it.
    static func touchDuringSleep(_ sleep: Int, _ watch: ExecutorWatch) -> WatchdogTouch {
        let touched = WatchdogTouch()
        let sleeps = WatchdogTouch()
        let hid = watch.hid
        let mac = watch.mac
        mac.change {
            $0.onSleep = {
                guard sleeps.count() == sleep else { return }
                let instant = mac.reading.monotonic.advanced(by: .milliseconds(-40))
                hid.personInput(at: instant)
                touched.mark(instant)
            }
        }
        return touched
    }

    static func expectWithinAbortBound(
        since touched: WatchdogTouch, mac: FakeMac, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let input = try #require(touched.instant, "the person never touched the Mac", sourceLocation: sourceLocation)
        let stoppedAfter = input.duration(to: mac.reading.monotonic)
        let bound = Duration.milliseconds(ContractConstants.userActivityAbortMs)
        #expect(stoppedAfter <= bound, "stopped \(stoppedAfter) after", sourceLocation: sourceLocation)
    }
}

/// When the person touched the Mac, and a counter for the hooks that decide when.
final class WatchdogTouch: Sendable {
    private let state = Mutex<(instant: ContinuousClock.Instant?, count: Int)>((nil, 0))

    var instant: ContinuousClock.Instant? { state.withLock(\.instant) }

    func mark(_ instant: ContinuousClock.Instant) { state.withLock { $0.instant = instant } }

    /// Counts one more call and returns the count.
    func count() -> Int {
        state.withLock {
            $0.count += 1
            return $0.count
        }
    }
}

/// The fake Mac as an owner whose snapshot still shows `lease`, as a snapshot read before a newer
/// lease was acquired would.
final class StaleLeaseOwner: WatchdogStateOwner {
    let mac: FakeMac
    let lease: LeaseManager

    init(mac: FakeMac, lease: LeaseManager) {
        self.mac = mac
        self.lease = lease
    }

    func snapshot() -> DeskSnapshot {
        var snapshot = mac.snapshot()
        snapshot.lease = lease
        return snapshot
    }

    func reduceNow(allowanceChanged: Bool) async {}
}

struct WatchdogFakeFault: Error {}

@Suite("Watchdog: polling the allowance file")
struct PollingFileChangeSourceTests {
    @Test("a change of the file or of its directory is reported at the next poll")
    func pollsSignatures() async {
        let clock = ManualScheduler()
        let signatures = FakeSignatures()
        signatures.set("/d", inode: 1)
        signatures.set("/d/f", inode: 2)
        let source = PollingFileChangeSource(
            paths: ["/d", "/d/f"], interval: .milliseconds(500), scheduler: clock, signature: signatures.signature)
        var changes = source.changes().makeAsyncIterator()
        await clock.waitForSleepers(1)
        #expect(clock.sleeperDeadlines == [WatchdogFixture.at(500).monotonic])

        clock.advance(byMilliseconds: 500)
        await clock.waitForSleepers(1)
        #expect(signatures.lookupCount == 4)

        signatures.set("/d/f", inode: nil)
        clock.advance(byMilliseconds: 500)
        #expect(await changes.next() != nil)
        await clock.waitForSleepers(1)
        #expect(clock.sleeperDeadlines == [WatchdogFixture.at(1500).monotonic])

        signatures.set("/d", inode: 3)
        clock.advance(byMilliseconds: 500)
        #expect(await changes.next() != nil)
        #expect(signatures.lookupCount == 8)
    }

    @Test("the default poll leaves half the deadline bound to stop the effect")
    func defaultInterval() {
        #expect(PollingFileChangeSource.defaultInterval == .milliseconds(500))
        let source = PollingFileChangeSource(
            allowance: AllowanceReader(path: "/var/db/deskhand/allowance.json", mac: "m", skewToleranceMs: 0))
        #expect(source.paths == ["/var/db/deskhand", "/var/db/deskhand/allowance.json"])
    }
}
