/// The deadline watchdog of contract 13: it stops the executing effect when the allowance, the
/// lease or the arming period ends or is revoked, and when the person at the Mac uses the keyboard
/// or pointer, and it retries the releases deskhand owes (contract 11.2).
///
/// It runs two loops, so a busy executor never holds up a read of the allowance file:
///
/// - The owner's loop has the owner read the allowance file again, bypassing its copy, every
///   ``Configuration/allowanceReadInterval``, and reduce whenever a deadline has passed. A change
///   of the file reported by a ``FileChangeSource`` does the same at once. None of these waits for
///   the executor: the executor reads the owner's new snapshot itself before its next event.
/// - The executor's loop passes everything that stops the effect to
///   ``WatchdogExecutor/interrupt(_:)``, which keeps the first cause in the order of contract 9.5
///   and ignores everything while no call is in the admission section, polls the person while an
///   operation executes, and calls ``WatchdogExecutor/retryCleanup(now:)``. It wakes at the
///   deadline, the next activity poll, the next cleanup retry, after every reduction, and at
///   ``refreshState()`` and ``executionDidChange(executing:)``.
///
/// A revocation is therefore noticed without any file-change source, by the periodic read, at most
/// ``Configuration/maxAllowanceReadInterval`` (500 ms) plus the timer's tolerance plus the owner's
/// reach after the change. The interruption reaches the executor as soon as the owner's reduction
/// returns, and the executor stops before its next event or within one 100 ms activity poll. That
/// leaves about 390 ms of `DEADLINE_BOUND_MS` for the owner to reach its reduction and for the
/// releases (contract 13.1, 14.4). A platform watch or a ``PollingFileChangeSource`` only makes it
/// sooner.
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
        /// not settle it, and how soon the owner's loop looks again while a reduction that another
        /// task started is still running.
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

    /// The two loops of ``run()``.
    private enum Loop {
        case owner, executor
    }

    /// One loop's sleep: until its wakeup, or until it is rung. A ring while the loop is awake makes
    /// its next sleep return at once, so a change it may have missed is evaluated.
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
    /// One reduction of the owner's at a time; a read of the file asked for meanwhile is carried
    /// into another pass.
    private var reducing = false
    private var allowanceChangePending = false
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
    /// `nil` when nothing can end.
    public static func deadline(of snapshot: DeskSnapshot) -> ContinuousClock.Instant? {
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
    /// both loops' wakeups. An owner may call it from inside its reduction: it starts no other.
    public func refreshState() async {
        _ = await evaluate()
        ring(.owner)
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
            let wakeup = await readIfDue()
            await sleep(.owner, until: wakeup)
        }
    }

    private func executorLoop() async {
        while !Task.isCancelled {
            let wakeup = await act(on: owner.snapshot())
            await sleep(.executor, until: wakeup)
        }
    }

    /// The owner's side: a read of the allowance file when the periodic read is due, a reduction
    /// when a deadline has passed. Returns when it is next due.
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
        // A reduction another task started is still running and carries the read asked for here.
        if reducing { return after.reading.monotonic.advanced(by: configuration.deadlineRetryInterval) }
        return [nextAllowanceRead, deadlineWakeup(of: after)].compactMap { $0 }.min()
    }

    /// The executor's side at `snapshot`'s reading. Returns when it is next due.
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

    /// When to act on the deadline next: at the deadline, or, once it has passed and the owner has
    /// not settled it, ``Configuration/deadlineRetryInterval`` from now.
    private func deadlineWakeup(of snapshot: DeskSnapshot) -> ContinuousClock.Instant? {
        guard let deadline = Self.deadline(of: snapshot) else { return nil }
        let now = snapshot.reading.monotonic
        return deadline > now ? deadline : now.advanced(by: configuration.deadlineRetryInterval)
    }

    /// The same rule as the executor's checks (contract 13.2): input within
    /// `USER_ACTIVITY_LOOKBACK_MS`, or an idle time that cannot be told, is activity.
    private func personInterruption() -> Interruption? {
        guard let idle = activity.idleMilliseconds() else { return .userActive(idleMs: 0) }
        return idle < ContractConstants.userActivityLookbackMs ? .userActive(idleMs: max(0, idle)) : nil
    }

    /// Has the owner reduce, reading the allowance file again when `allowanceChanged`. Returns at
    /// once while another reduction runs, which then makes one more pass for a read asked for
    /// meanwhile. The next periodic read is scheduled from the start of the pass that reads, before
    /// waiting on the owner, so an owner that calls ``refreshState()`` from inside its reduction
    /// does not start another.
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
    }

    /// Returns at `wakeup`, when the loop is rung, or when the task is cancelled.
    private func sleep(_ loop: Loop, until wakeup: ContinuousClock.Instant?) async {
        if alarms[loop, default: Alarm()].rangWhileAwake {
            alarms[loop, default: Alarm()].rangWhileAwake = false
            return
        }
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

    /// A timer from an earlier sleep is ignored.
    private func endSleep(_ loop: Loop, generation: UInt64) {
        guard generation == alarms[loop, default: Alarm()].generation,
            let sleeper = alarms[loop, default: Alarm()].sleeper
        else { return }
        alarms[loop, default: Alarm()].sleeper = nil
        sleeper.resume()
    }
}
