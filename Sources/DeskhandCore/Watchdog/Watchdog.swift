/// The deadline watchdog of contract 13: it stops the executing effect when the allowance, the
/// lease or the arming period ends or is revoked, and when the person at the Mac uses the keyboard
/// or pointer, and it retries the releases deskhand owes (contract 11.2).
///
/// It works to one wakeup, the earliest of the deadline, the next activity poll while an effect
/// executes, the next cleanup retry and the next periodic read of the allowance, and it is woken
/// early by ``refreshState()``, ``executionDidChange(executing:)`` and a change of the allowance
/// file. Every evaluation passes what it finds to ``WatchdogExecutor/interrupt(_:)``, which keeps
/// the first cause in the order of contract 9.5 and ignores everything while no call is in the
/// admission section, and then calls ``WatchdogExecutor/retryCleanup(now:)``.
///
/// One instance per Mac. The app calls ``run()`` once, on a task it cancels at stop.
public actor Watchdog {
    public struct Configuration: Hashable, Sendable {
        /// `USER_ACTIVITY_POLL_MS`.
        public var activityPollInterval: Duration
        /// How often the allowance is read again whether or not calls arrive (contract 14.4).
        public var allowanceReadInterval: Duration
        /// How soon a deadline that has passed is acted on again, when the owner's reduction did
        /// not settle it.
        public var deadlineRetryInterval: Duration

        public init(
            activityPollInterval: Duration = .milliseconds(ContractConstants.userActivityPollMs),
            allowanceReadInterval: Duration = .milliseconds(ContractConstants.allowanceCacheMaxMs),
            deadlineRetryInterval: Duration = .milliseconds(ContractConstants.userActivityPollMs)
        ) {
            self.activityPollInterval = activityPollInterval
            self.allowanceReadInterval = allowanceReadInterval
            self.deadlineRetryInterval = deadlineRetryInterval
        }
    }

    private let owner: any WatchdogStateOwner
    private let executor: any WatchdogExecutor
    private let activity: any UserActivitySource
    private let fileChanges: [any FileChangeSource]
    private let scheduler: any WatchdogScheduler
    private let configuration: Configuration

    private var executing = false
    private var nextActivityPoll: ContinuousClock.Instant?
    private var nextAllowanceRead: ContinuousClock.Instant?
    /// One reduction of the owner's at a time; changes of the file that arrive meanwhile are
    /// carried into the next.
    private var reducing = false
    private var allowanceChangePending = false
    private var sleeper: CheckedContinuation<Void, Never>?
    private var wakePending = false
    private var sleepGeneration: UInt64 = 0

    /// `activity` is the same source the executor was built with, normally a
    /// ``PersonActivitySource``. `fileChanges` watch the allowance file: the platform's watch and a
    /// ``PollingFileChangeSource``.
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

    /// Runs until the calling task is cancelled: the wakeups, and every ``FileChangeSource``.
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            for source in fileChanges {
                group.addTask {
                    for await _ in source.changes() { await self.allowanceFileDidChange() }
                }
            }
            group.addTask { await self.wakeLoop() }
            await group.waitForAll()
        }
    }

    /// The signals changed: a reduction, a `lease` call or a read of the allowance. Evaluates at
    /// once, so the executor and the cleanup retry see the change now (contract 11.2), and moves
    /// the wakeup.
    public func refreshState() async {
        _ = await evaluate()
        wake()
    }

    /// From ``ExecutorObserver/executionDidChange(executing:)``. The activity poll runs only while
    /// an operation executes, and starts at once.
    public func executionDidChange(executing: Bool) async {
        self.executing = executing
        nextActivityPoll = nil
        _ = await evaluate()
        wake()
    }

    /// The allowance file may have changed: the owner reads it again, bypassing its copy, and
    /// reduces; a revocation then stops the executing effect at once (contract 13.1, 14.4).
    public func allowanceFileDidChange() async {
        await reduce(allowanceChanged: true)
        _ = await act(on: owner.snapshot())
        wake()
    }

    /// One evaluation at the owner's clock reading. Has the owner reduce when the deadline has
    /// passed or the periodic read of the allowance is due, passes every cause it finds to the
    /// executor, polls the person while an operation executes, retries cleanup, and returns when it
    /// next needs to run: `nil` when nothing is due until something changes.
    public func evaluate() async -> ContinuousClock.Instant? {
        var snapshot = owner.snapshot()
        let now = snapshot.reading.monotonic
        let readDue = nextAllowanceRead.map { $0 <= now } ?? true
        let deadlinePassed = Self.deadline(of: snapshot).map { $0 <= now } ?? false
        if readDue || deadlinePassed {
            await reduce(allowanceChanged: false)
            snapshot = owner.snapshot()
        }
        return await act(on: snapshot)
    }

    private func act(on snapshot: DeskSnapshot) async -> ContinuousClock.Instant? {
        let now = snapshot.reading
        for interruption in Self.interruptions(at: snapshot) { await executor.interrupt(interruption) }
        if executing, nextActivityPoll.map({ $0 <= now.monotonic }) ?? true {
            nextActivityPoll = now.monotonic.advanced(by: configuration.activityPollInterval)
            if let person = personInterruption() { await executor.interrupt(person) }
        }
        _ = await executor.retryCleanup(now: now)
        var wakeups = [nextAllowanceRead, await executor.nextCleanupRetry(at: now)]
        if executing { wakeups.append(nextActivityPoll) }
        if let deadline = Self.deadline(of: snapshot) {
            wakeups.append(
                deadline > now.monotonic ? deadline : now.monotonic.advanced(by: configuration.deadlineRetryInterval))
        }
        return wakeups.compactMap { $0 }.min()
    }

    /// The same rule as the executor's checks (contract 13.2): input within
    /// `USER_ACTIVITY_LOOKBACK_MS`, or an idle time that cannot be told, is activity.
    private func personInterruption() -> Interruption? {
        guard let idle = activity.idleMilliseconds() else { return .userActive(idleMs: 0) }
        return idle < ContractConstants.userActivityLookbackMs ? .userActive(idleMs: max(0, idle)) : nil
    }

    /// Has the owner reduce. The next periodic read is scheduled before waiting on the owner, so
    /// an owner that calls ``refreshState()`` from inside its reduction does not start another.
    private func reduce(allowanceChanged: Bool) async {
        allowanceChangePending = allowanceChangePending || allowanceChanged
        guard !reducing else { return }
        reducing = true
        repeat {
            let changed = allowanceChangePending
            allowanceChangePending = false
            nextAllowanceRead = owner.snapshot().reading.monotonic.advanced(by: configuration.allowanceReadInterval)
            await owner.reduceNow(allowanceChanged: changed)
        } while allowanceChangePending
        reducing = false
    }

    private func wakeLoop() async {
        while !Task.isCancelled {
            let wakeup = await evaluate()
            await sleep(until: wakeup)
        }
    }

    /// Returns at `wakeup`, at ``wake()``, or when the task is cancelled. A ``wake()`` that came
    /// while the loop was evaluating makes it return at once.
    private func sleep(until wakeup: ContinuousClock.Instant?) async {
        if wakePending {
            wakePending = false
            return
        }
        sleepGeneration &+= 1
        let generation = sleepGeneration
        let timer = wakeup.map { wakeup in
            Task { [scheduler] in
                await scheduler.sleep(until: wakeup)
                await self.endSleep(generation: generation)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { sleeper = $0 }
        } onCancel: {
            Task { await self.wake() }
        }
        timer?.cancel()
    }

    private func wake() {
        guard let sleeper else {
            wakePending = true
            return
        }
        self.sleeper = nil
        sleeper.resume()
    }

    /// A timer from an earlier sleep is ignored.
    private func endSleep(generation: UInt64) {
        guard generation == sleepGeneration, let sleeper else { return }
        self.sleeper = nil
        sleeper.resume()
    }
}
