/// What the executor reads about the Mac before admission and before every event: the state, the
/// lease, the app policy in force, and the clock reading all three are judged at.
public struct DeskSnapshot: Sendable {
    public var reading: ClockReading
    public var report: StateReport
    public var lease: LeaseManager
    public var policy: AppPolicy

    public init(reading: ClockReading, report: StateReport, lease: LeaseManager, policy: AppPolicy) {
        self.reading = reading
        self.report = report
        self.lease = lease
        self.policy = policy
    }

    /// The state at ``reading``: a report goes stale when arming or the allowance runs out.
    public var state: DeskhandState { report.state(at: reading) }

    /// Whether releases may be posted now (contract 12.8), judged on every blocking condition.
    public var cleanupAuthorization: CleanupAuthorization {
        CleanupAuthorization(active: report.activeStates(at: reading), conditions: report.conditions)
    }
}

/// The owner of the state, the lease and the configuration, as the executor sees it. The executor
/// reads it between the ledger write and the post of every event, so ``snapshot()`` must not wait:
/// the owner keeps its current report, lease and policy where this can read them at once.
public protocol StateSource: Sendable {
    /// The state, the lease and the policy as they stand, judged at ``DeskSnapshot/reading``, which
    /// MUST be ``ClockReading/now()`` read inside this call, never a reading kept from the last
    /// reduction: the executor takes it as now for the deadline, the lease's expiry, the patch
    /// check's age, the length of a hold and the times it records (contract 8.4, 13).
    func snapshot() -> DeskSnapshot
}

/// What ``FrameSource/check(_:in:for:now:)`` found.
public enum FrameCheck: Sendable {
    /// Passed every staleness check but `pixels_changed`. Its ``Frame/sha256`` is the digest the
    /// intent entry names (contract 12.10).
    case valid(LiveFrame)
    /// `sha256` when deskhand still knows the frame, for the refusal entry.
    case stale(StaleFrameReason, sha256: SHA256Hex?)
}

/// The frames of contract 4.2, held by whoever records screenshots.
public protocol FrameSource: Sendable {
    /// Refusal step 9: ``FrameStore/check(_:in:for:displayConfigGeneration:now:)`` against the
    /// display configuration generation in force.
    func check(_ id: FrameID, in scope: FrameScope, for use: FrameUse, now: Timestamp) async -> FrameCheck
}

extension FrameStore {
    /// ``validate(_:in:for:displayConfigGeneration:now:)`` as refusal step 9 answers it: a stale
    /// frame that the store still has names its digest.
    public func check(
        _ id: FrameID, in scope: FrameScope, for use: FrameUse, displayConfigGeneration: DisplayConfigGeneration,
        now: Timestamp
    ) -> FrameCheck {
        switch validate(id, in: scope, for: use, displayConfigGeneration: displayConfigGeneration, now: now) {
        case .valid(let live): .valid(live)
        case .stale(let reason): .stale(reason, sha256: lookup(id, in: scope)?.sha256)
        }
    }
}

/// The person at the Mac (contract 13.2).
public protocol UserActivitySource: Sendable {
    /// Milliseconds since the person's last keyboard or pointer input, not counting deskhand's own
    /// events. `nil` when the idle signal cannot be read or deskhand's events cannot be told apart:
    /// that counts as activity.
    func idleMilliseconds() -> Int?
}

/// The connection that carried one effect call (contract 9.5, 12.3).
public protocol ConnectionLiveness: Sendable {
    /// `false` once deskhand has observed the connection closed (contract 12.5).
    var isOpen: Bool { get }
}

/// The connection is the task that runs the call: the server cancels a request's task when its
/// connection closes. Only meaningful when read from inside that task, which is where the executor
/// runs a call.
public struct TaskCancellationLiveness: ConnectionLiveness {
    public init() {}

    public var isOpen: Bool { !Task.isCancelled }
}

/// Waits inside an operation: the hold of a key, the pacing of a drag and the activity poll between
/// (contract 13.2).
public protocol ExecutionTimer: Sendable {
    /// Returns after `duration`, or earlier; the executor checks again either way.
    func sleep(for duration: Duration) async
}

/// `Task.sleep`. A cancelled task returns at once, and the executor's next check sees the closed
/// connection.
public struct TaskSleepTimer: ExecutionTimer {
    public init() {}

    public func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

/// What the executor tells the owners of the state and the conditions. Called on the executor
/// without waiting, so a conformer only records.
public protocol ExecutorObserver: Sendable {
    /// An operation was admitted, or the admission section was left. Arming is not accepted while
    /// one executes (contract 10.4).
    func executionDidChange(executing: Bool)

    /// deskhand posted an event (``OwnInputActivity/lastPostedEvent``).
    func didPostEvent(at instant: ContinuousClock.Instant)

    /// An append to the action log succeeded or failed: `log_unavailable` (contract 11.3).
    func actionLogDidAppend(succeeded: Bool)

    /// The ledger holds entries, or cannot be read and so may hold some, while no operation
    /// executes; or no longer does: `cleanup_pending` (contract 11.2).
    func cleanupPendingDidChange(_ pending: Bool)
}

/// Builds the operation store from its file: at start, and again when a failed write left it
/// unavailable and no operation is in the admission section (contract 12.3, 12.9).
public protocol OperationStoreLoader: Sendable {
    func load(now: Timestamp) throws(OperationStoreLoadError) -> OperationStore
}
