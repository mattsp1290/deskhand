/// The deadline watchdog of contract 13: it stops the executing effect when the allowance, the
/// lease or the arming period ends or is revoked, and when the person at the Mac uses the keyboard
/// or pointer, and it retries the releases deskhand owes (contract 11.2).
///
/// It runs two loops, so a busy executor never holds up a read of the allowance file:
///
/// - The owner's loop has the owner read the allowance file again, bypassing its copy, every
///   ``Configuration/allowanceReadInterval``, and reduce whenever a deadline has passed. An owner
///   that commits a lapse when any read finds it, its own loop's snapshot among them, keeps the
///   deadline passed through ``DeskSnapshot/hasUnreducedEffects`` (``deadline(of:)``), so the loop
///   reduces at its wake at the deadline, not at the next periodic read. A wall clock stepped
///   forward across `expires_at` can bring the lapse before that wake; the loop's next wake reduces
///   it, the periodic read at the latest. A change of the file
///   reported by a ``FileChangeSource`` reduces at once. None of these waits for the executor: the
///   executor reads the owner's new snapshot itself before its next event.
/// - The executor's loop passes everything that stops the effect to
///   ``WatchdogExecutor/interrupt(_:)``, which keeps the first cause in the order of contract 9.5
///   and ignores everything while no call is in the admission section, polls the person while an
///   operation executes, and calls ``WatchdogExecutor/retryCleanup(now:)``. It wakes at the
///   deadline (``Configuration/deadlineRetryInterval`` after it once it has passed, as while
///   effects wait for a reduction), the next activity poll, the next cleanup retry, after every
///   reduction, and at ``refreshState()`` and ``executionDidChange(executing:)``.
///
/// A revocation is therefore noticed without any file-change source, by the periodic read, at most
/// ``Configuration/maxAllowanceReadInterval`` (500 ms) plus the timer's tolerance plus the owner's
/// reach after the change. The interruption reaches the executor as soon as the owner's reduction
/// returns, and the executor stops before its next event or within one 100 ms activity poll. That
/// leaves about 390 ms of `DEADLINE_BOUND_MS` for the owner to reach its reduction and for the
/// releases (contract 13.1, 14.4). A platform watch or a ``PollingFileChangeSource`` only makes it
/// sooner. A lapse the clock alone makes is reduced at the owner's wake at its deadline, plus the
/// timer's tolerance, or ``Configuration/deadlineRetryInterval`` later when a read commits it after
/// the owner's reduction. A lapse a wall clock stepped forward brings earlier waits for the
/// periodic read at most, as a revocation does.
///
/// One instance per Mac. The app calls ``run()`` once, on a task it cancels at stop.
public actor Watchdog {
    public struct Configuration: Hashable, Sendable {
        /// The longest ``allowanceReadInterval`` the watchdog uses: half of `DEADLINE_BOUND_MS`, so a
        /// revocation that only the periodic read notices leaves the other half to reach the owner,
        /// stop the effect and release its input.
        public static let maxAllowanceReadInterval: Duration = .milliseconds(ContractConstants.deadlineBoundMs / 2)

        /// `USER_ACTIVITY_POLL_MS`.
        public var activityPollInterval: Duration
        /// How often the owner reads the allowance file again, bypassing its copy, whether or not
        /// calls arrive or a file-change source reports anything (contract 14.4). A longer value
        /// than ``maxAllowanceReadInterval`` is shortened to it.
        public var allowanceReadInterval: Duration
        /// How soon a deadline that has passed is acted on again, when the owner's reduction did
        /// not settle it or a read committed another lapse after it, and how soon the owner's loop
        /// looks again while a reduction that another task started is still running. A refresh that
        /// leaves a passed deadline while the owner's loop is reducing is therefore acted on by the
        /// owner up to this much later; the executor's loop is woken at once either way.
        public var deadlineRetryInterval: Duration

        public init(
            activityPollInterval: Duration = .milliseconds(ContractConstants.userActivityPollMs),
            allowanceReadInterval: Duration = maxAllowanceReadInterval,
            deadlineRetryInterval: Duration = .milliseconds(ContractConstants.userActivityPollMs)
        ) {
            self.activityPollInterval = activityPollInterval
            self.allowanceReadInterval = allowanceReadInterval
            self.deadlineRetryInterval = deadlineRetryInterval
        }
    }

    private enum Loop {
        case owner, executor
    }

    private struct Alarm {
        var sleeper: CheckedContinuation<Void, Never>?
        var rangWhileAwake = false
        var generation: UInt64 = 0
    }

    private let owner: any WatchdogStateOwner
    private let executor: any WatchdogExecutor
    private let activity: any UserActivitySource
    private let fileChanges: [any FileChangeSource]
    private let scheduler: any WatchdogScheduler
    private let configuration: Configuration
    private let allowanceReadInterval: Duration

    private var nextActivityPoll: ContinuousClock.Instant?
    private var nextAllowanceRead: ContinuousClock.Instant?
    private var reducing = false
    private var allowanceChangePending = false
    private var ownerRangDuringReduction = false
    private var alarms: [Loop: Alarm] = [.owner: Alarm(), .executor: Alarm()]

    /// `activity` is the same source the executor was built with, normally a
    /// ``PersonActivitySource``. `fileChanges` watch the allowance file, the platform's watch and a
    /// ``PollingFileChangeSource``; without them the periodic read alone keeps the bound.
    public init(
        owner: any WatchdogStateOwner, executor: any WatchdogExecutor, activity: any UserActivitySource,
        fileChanges: [any FileChangeSource] = [], scheduler: any WatchdogScheduler = ContinuousClockScheduler(),
        configuration: Configuration = Configuration()
    ) {
        self.owner = owner
        self.executor = executor
        self.activity = activity
        self.fileChanges = fileChanges
        self.scheduler = scheduler
        self.configuration = configuration
        allowanceReadInterval = min(configuration.allowanceReadInterval, Configuration.maxAllowanceReadInterval)
    }

    /// The deadline of contract 13.1 at `snapshot`'s reading: the earliest of the allowance's
    /// `expires_at`, the held lease's expiry and the end of arming, read afresh so a renewal moves
    /// it. Already past when a lease is held while the allowance or arming has ended. With no lease
    /// held it is when the clock alone next changes the state (``StateReport/validUntil(at:)``);
    /// `nil` when nothing can end. The snapshot's reading while it shows
    /// ``DeskSnapshot/hasUnreducedEffects``: an owner that commits the clock's transitions when
    /// anything reads it has already moved its report past the deadline that queued them, which
    /// has passed all the same until a reduction returns them.
    public static func deadline(of snapshot: DeskSnapshot) -> ContinuousClock.Instant? {
        if snapshot.hasUnreducedEffects { return snapshot.reading.monotonic }
        if case .held(let lease) = snapshot.lease.lease {
            return snapshot.report.effectDeadline(of: lease, leases: snapshot.lease, at: snapshot.reading)
        }
        return snapshot.report.validUntil(at: snapshot.reading)
    }

    /// What stops an executing effect at `snapshot`'s reading, apart from the person: a state that
    /// is not `ok`, which includes an allowance or an arming period that has ended, and a lease
    /// that has run out.
    public static func interruptions(at snapshot: DeskSnapshot) -> [Interruption] {
        var found: [Interruption] = []
        if let blocking = snapshot.state.blocking { found.append(.state(blocking)) }
        if case .expired(let last) = snapshot.lease.state(at: snapshot.reading) {
            found.append(.leaseEnded(LeaseEnd(lease: last, cause: .expired)))
        }
        return found
    }

    /// Runs until the calling task is cancelled: both loops, and every ``FileChangeSource``.
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            for source in fileChanges {
                group.addTask {
                    for await _ in source.changes() { await self.allowanceFileDidChange() }
                }
            }
            group.addTask { await self.ownerLoop() }
            group.addTask { await self.executorLoop() }
            await group.waitForAll()
        }
    }

    /// The signals changed: a reduction, a `lease` call or a read of the allowance. Evaluates at
    /// once, so the executor and the cleanup retry see the change now (contract 11.2), and moves
    /// both loops' wakeups. An owner may call it from inside its reduction: while a reduction runs
    /// it only wakes the executor's loop, so it starts no other reduction, and the reduction never
    /// waits for the executor through it. The executor's loop then evaluates, and the owner's loop
    /// looks again once the reduction ends. Call it only once the change is in the owner's
    /// ``StateSource/snapshot()``: the owner's loop drops a ring that arrives while it is awake and
    /// relies on the snapshot it reads next.
    public func refreshState() async {
        if reducing {
            ownerRangDuringReduction = true
        } else {
            _ = await evaluate()
            ring(.owner)
        }
        ring(.executor)
    }

    /// From ``ExecutorObserver/executionDidChange(executing:)``. The watchdog asks the executor
    /// whether an operation executes, so changes that arrive out of order do no harm: this only
    /// evaluates at once, and a new execution's activity poll starts at once.
    public func executionDidChange(executing: Bool) async {
        nextActivityPoll = nil
        _ = await evaluate()
        ring(.executor)
    }

    /// The allowance file may have changed: the owner reads it again, bypassing its copy, and
    /// reduces; the executor's loop then passes a revocation to the executor, and both loops wake
    /// for a deadline the file moved (contract 13.1, 14.4). Waits for the owner, never for the
    /// executor; returns at once while another reduction runs, which then reads the file again.
    public func allowanceFileDidChange() async {
        await reduce(allowanceChanged: true)
        ring(.owner)
        ring(.executor)
    }

    /// One evaluation at the owner's clock reading: the owner's side, then the executor's. Has the
    /// owner read the allowance file when the periodic read is due and reduce when a deadline has
    /// passed, passes every cause it finds to the executor, polls the person while an operation
    /// executes, retries cleanup, and returns when it next needs to run: `nil` when nothing is due
    /// until something changes.
    public func evaluate() async -> ContinuousClock.Instant? {
        let ownerWakeup = await readIfDue()
        let executorWakeup = await act(on: owner.snapshot())
        return [ownerWakeup, executorWakeup].compactMap { $0 }.min()
    }

    private func ownerLoop() async {
        while !Task.isCancelled {
            // `wakeup` comes from the snapshot readIfDue takes after the loop's last suspension, so
            // a ring that reached this loop while it was awake, its own reduction's deferred ring
            // among them, is already in it. Keeping that ring would end the sleep at once and
            // reduce a passed deadline the owner does not settle again without the pause of
            // ``Configuration/deadlineRetryInterval``. Do not add an `await` between that snapshot
            // and this sleep: a ring that arrived there would be dropped.
            let wakeup = await readIfDue()
            await sleep(.owner, until: wakeup, keepingRingsWhileAwake: false)
        }
    }

    private func executorLoop() async {
        while !Task.isCancelled {
            let wakeup = await act(on: owner.snapshot())
            await sleep(.executor, until: wakeup, keepingRingsWhileAwake: true)
        }
    }

    private func readIfDue() async -> ContinuousClock.Instant? {
        let snapshot = owner.snapshot()
        let now = snapshot.reading.monotonic
        let readDue = nextAllowanceRead.map { $0 <= now } ?? true
        let deadlinePassed = Self.deadline(of: snapshot).map { $0 <= now } ?? false
        if readDue || deadlinePassed {
            await reduce(allowanceChanged: readDue)
            ring(.executor)
        }
        let after = owner.snapshot()
        if reducing { return after.reading.monotonic.advanced(by: configuration.deadlineRetryInterval) }
        return [nextAllowanceRead, deadlineWakeup(of: after)].compactMap { $0 }.min()
    }

    private func act(on snapshot: DeskSnapshot) async -> ContinuousClock.Instant? {
        let now = snapshot.reading
        for interruption in Self.interruptions(at: snapshot) { await executor.interrupt(interruption) }
        let executing = await executor.isExecuting
        if !executing {
            nextActivityPoll = nil
        } else if nextActivityPoll.map({ $0 <= now.monotonic }) ?? true {
            nextActivityPoll = now.monotonic.advanced(by: configuration.activityPollInterval)
            if let person = personInterruption() { await executor.interrupt(person) }
        }
        _ = await executor.retryCleanup(now: now)
        let cleanupRetry = await executor.nextCleanupRetry(at: now)
        return [cleanupRetry, nextActivityPoll, deadlineWakeup(of: snapshot)].compactMap { $0 }.min()
    }

    private func deadlineWakeup(of snapshot: DeskSnapshot) -> ContinuousClock.Instant? {
        guard let deadline = Self.deadline(of: snapshot) else { return nil }
        let now = snapshot.reading.monotonic
        return deadline > now ? deadline : now.advanced(by: configuration.deadlineRetryInterval)
    }

    private func personInterruption() -> Interruption? {
        guard let idle = activity.idleMilliseconds() else { return .userActive(idleMs: 0) }
        return idle < ContractConstants.userActivityLookbackMs ? .userActive(idleMs: max(0, idle)) : nil
    }

    /// A refresh from inside the reduction rings the owner's loop once the reduction ends, so a
    /// loop that slept through a reduction another task ran looks again at once. When the owner's
    /// loop ran the reduction itself, the loop drops that ring before it sleeps.
    private func reduce(allowanceChanged: Bool) async {
        allowanceChangePending = allowanceChangePending || allowanceChanged
        guard !reducing else { return }
        reducing = true
        repeat {
            let reads = allowanceChangePending
            allowanceChangePending = false
            if reads {
                nextAllowanceRead = owner.snapshot().reading.monotonic.advanced(by: allowanceReadInterval)
            }
            await owner.reduceNow(allowanceChanged: reads)
        } while allowanceChangePending
        reducing = false
        if ownerRangDuringReduction {
            ownerRangDuringReduction = false
            ring(.owner)
        }
    }

    /// Without `keepingRingsWhileAwake`, a ring that arrived while the loop was awake is dropped
    /// rather than ending this sleep at once: the caller computed `wakeup` from state read after
    /// that ring. Nothing here suspends before the continuation is installed, so with a caller that
    /// does not suspend between that read and this call either, no ring is lost.
    private func sleep(_ loop: Loop, until wakeup: ContinuousClock.Instant?, keepingRingsWhileAwake: Bool) async {
        let rang = alarms[loop, default: Alarm()].rangWhileAwake
        alarms[loop, default: Alarm()].rangWhileAwake = false
        if rang && keepingRingsWhileAwake { return }
        alarms[loop, default: Alarm()].generation &+= 1
        let generation = alarms[loop, default: Alarm()].generation
        let timer = wakeup.map { wakeup in
            Task { [scheduler] in
                await scheduler.sleep(until: wakeup)
                self.endSleep(loop, generation: generation)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { alarms[loop, default: Alarm()].sleeper = $0 }
        } onCancel: {
            Task { await self.ring(loop) }
        }
        timer?.cancel()
    }

    private func ring(_ loop: Loop) {
        guard let sleeper = alarms[loop, default: Alarm()].sleeper else {
            alarms[loop, default: Alarm()].rangWhileAwake = true
            return
        }
        alarms[loop, default: Alarm()].sleeper = nil
        sleeper.resume()
    }

    private func endSleep(_ loop: Loop, generation: UInt64) {
        guard generation == alarms[loop, default: Alarm()].generation,
            let sleeper = alarms[loop, default: Alarm()].sleeper
        else { return }
        alarms[loop, default: Alarm()].sleeper = nil
        sleeper.resume()
    }
}
