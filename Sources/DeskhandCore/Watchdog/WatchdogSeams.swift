/// The watchdog's timer. Tests supply a manual one, so nothing in them sleeps for real.
public protocol WatchdogScheduler: Sendable {
    /// The monotonic clock now.
    var now: ContinuousClock.Instant { get }

    /// Returns at `deadline`, at once when it has passed, or earlier when the calling task is
    /// cancelled.
    func sleep(until deadline: ContinuousClock.Instant) async
}

/// `Task.sleep` on the continuous clock, with an explicit tolerance: the system's default leeway
/// grows with the length of the sleep, and every wakeup of the watchdog counts against a bound of
/// contract 13.
public struct ContinuousClockScheduler: WatchdogScheduler {
    /// How late a wakeup may be, at most.
    public let tolerance: Duration

    public init(tolerance: Duration = .milliseconds(10)) { self.tolerance = tolerance }

    public var now: ContinuousClock.Instant { .now }

    public func sleep(until deadline: ContinuousClock.Instant) async {
        try? await Task.sleep(until: deadline, tolerance: tolerance, clock: .continuous)
    }
}

/// What the watchdog asks of the executor (contract 11.2, 13). ``InputExecutor`` conforms.
public protocol WatchdogExecutor: Sendable {
    /// ``InputExecutor/isExecuting``.
    var isExecuting: Bool { get async }

    /// ``InputExecutor/interrupt(_:)``.
    func interrupt(_ interruption: Interruption) async

    /// ``InputExecutor/retryCleanup(now:)``.
    func retryCleanup(now: ClockReading) async -> OwedRelease?

    /// ``InputExecutor/nextCleanupRetry(at:)``.
    func nextCleanupRetry(at now: ClockReading) async -> ContinuousClock.Instant?
}

extension InputExecutor: WatchdogExecutor {
    /// Whether an admitted operation is executing: the watchdog polls the person only then. Asked
    /// rather than told, so it never depends on the order in which observer calls arrive.
    public var isExecuting: Bool {
        if case .executing = section { true } else { false }
    }
}

/// The owner of the state, the lease and the allowance cache (the app), as the watchdog drives it.
/// ``StateSource/snapshot()`` is the snapshot the executor reads, with the clock reading the
/// watchdog judges every deadline at.
public protocol WatchdogStateOwner: StateSource {
    /// Reads the signals again and reduces at the current clock reading, carrying out the effects
    /// in order (``TransitionEffect``); settles a lease that has run out with
    /// ``LeaseManager/expire(now:)``; and, when `allowanceChanged`, first drops the copy of the
    /// allowance with ``AllowanceCache/invalidate()`` so the file is read again. The new snapshot is
    /// in place when it returns. The watchdog calls it when the allowance file may have changed,
    /// when a deadline has passed, when a snapshot shows ``DeskSnapshot/hasUnreducedEffects``, and
    /// with `allowanceChanged` at least every ``Watchdog/Configuration/allowanceReadInterval``.
    ///
    /// An owner that commits the clock's transitions when anything reads it, its
    /// ``StateSource/snapshot()`` among them, MUST set ``DeskSnapshot/hasUnreducedEffects`` while
    /// their effects wait for a reduction: the committed
    /// transition is no longer a passed deadline, so without it the watchdog reduces only at the
    /// next periodic read. This call MUST carry those effects out with its own and clear the flag,
    /// so a later snapshot sets it again only when a newer read committed another transition; while
    /// it stays set the watchdog reduces again every ``Watchdog/Configuration/deadlineRetryInterval``.
    ///
    /// It passes what the reduction stops (a ``TransitionEffect/cancelInFlight(_:)``, a lease it
    /// ended) to ``InputExecutor/interrupt(_:)`` as soon as it has reduced, since a state that ends
    /// again before the watchdog looks leaves nothing in the snapshot. Otherwise it should not wait
    /// for the executor: the watchdog passes what the new snapshot stops and retries the cleanup
    /// itself, and the time this takes counts against the bound of contract 13.1.
    ///
    /// It may call ``Watchdog/refreshState()`` from inside, and then awaits it here rather than on
    /// another task: a refresh that lands after the reduction ends evaluates and wakes the owner's
    /// loop at once, so a passed deadline it leaves unsettled would be reduced, and refreshed,
    /// again without the pause of ``Watchdog/Configuration/deadlineRetryInterval``.
    func reduceNow(allowanceChanged: Bool) async
}
