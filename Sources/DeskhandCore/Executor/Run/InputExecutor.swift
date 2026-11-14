/// The single serial executor of this Mac (contract 9.5, 12): the one place where admission, the
/// refusal checks, the operation records, the held-input ledger, the action log and posting meet.
///
/// It owns the admission section, the action ceiling, the operation store and the ledger, so every
/// record lookup, admission, ledger write and release goes through it in turn. One call at a time
/// is inside the section, from refusal step 3 to its final record write; a call that arrives
/// meanwhile is answered at once with `busy`, `operation_in_progress` or `operation_id_conflict`,
/// because the executing call yields after every event and while it waits. Between the ledger
/// write, the checks and the post of an event nothing else runs: those seams answer synchronously.
public actor InputExecutor {
    public struct Configuration: Hashable, Sendable {
        /// `ACTIONS_PER_MINUTE`.
        public var actionsPerMinute: Int

        public init(actionsPerMinute: Int = ContractConstants.defaultActionsPerMinute) {
            self.actionsPerMinute = actionsPerMinute
        }

        public init(limits: Limits) { self.init(actionsPerMinute: limits.actionsPerMinute) }
    }

    /// Everything outside core that the executor reads, posts through or reports to.
    public struct Seams: Sendable {
        public var state: any StateSource
        public var frames: any FrameSource
        public var patches: any TargetPatchVerifier
        public var identity: any IdentityMeasurer
        public var activity: any UserActivitySource
        public var poster: any EventPoster
        public var keyCodes: any KeyCodeMapper
        public var log: any ActionLogClient
        public var timer: any ExecutionTimer
        public var releases: any ReleaseHandler
        public var observer: any ExecutorObserver
        public var operationStore: any OperationStoreLoader

        public init(
            state: any StateSource, frames: any FrameSource, patches: any TargetPatchVerifier,
            identity: any IdentityMeasurer, activity: any UserActivitySource, poster: any EventPoster,
            keyCodes: any KeyCodeMapper, log: any ActionLogClient, timer: any ExecutionTimer = TaskSleepTimer(),
            releases: any ReleaseHandler = LedgerReleaseHandler(), observer: any ExecutorObserver,
            operationStore: any OperationStoreLoader
        ) {
            self.state = state
            self.frames = frames
            self.patches = patches
            self.identity = identity
            self.activity = activity
            self.poster = poster
            self.keyCodes = keyCodes
            self.log = log
            self.timer = timer
            self.releases = releases
            self.observer = observer
            self.operationStore = operationStore
        }
    }

    let seams: Seams
    var ceiling: ActionCeiling
    /// `nil` when it could not be loaded; every effect is then `internal_error` (contract 12.3).
    var store: OperationStore?
    var ledger: HeldInputLedger
    var section: AdmissionSection = .idle
    /// What the watchdog asked to stop the call in the section with, until that call leaves.
    var interruption: Interruption?

    /// Loads the operation store, which applies the restart rules (contract 12.9), and takes the
    /// ledger as the previous run left it: any entry is owed a release.
    public init(
        configuration: Configuration = Configuration(), seams: Seams, ledger: consuming sending HeldInputLedger,
        now: Timestamp
    ) {
        let owesReleases = !ledger.pending().isEmpty
        self.seams = seams
        ceiling = ActionCeiling(actionsPerMinute: configuration.actionsPerMinute)
        store = try? seams.operationStore.load(now: now)
        self.ledger = ledger
        seams.observer.cleanupPendingDidChange(owesReleases)
    }

    /// Whether the record file and the ledger can be written. While either cannot, every effect
    /// call is refused with `internal_error` (contract 12.3).
    public var storesAvailable: Bool { (store?.isAvailable ?? false) && ledger.isAvailable }

    /// Whether a call is being admitted or is executing.
    public var isInSection: Bool { !section.isIdle }

    /// `cleanup_pending` (contract 11.2): the ledger holds entries and no operation executes.
    public var owesReleases: Bool { section.isIdle && !ledger.pending().isEmpty }

    /// Stops the call in the admission section with `interruption` at its next check: before its
    /// next event, or within one activity poll while it waits (contract 13). A call that has not
    /// reached its last look stops there. When several arrive, the one first in the order of
    /// contract 9.5 wins. Ignored while the section is empty.
    public func interrupt(_ interruption: Interruption) {
        guard !section.isIdle else { return }
        if let current = self.interruption, current.reason.abortRank <= interruption.reason.abortRank { return }
        self.interruption = interruption
    }

    /// `status.operation` (contract 6.1): the record for `key`, or a call with that key still being
    /// admitted as `accepted` with 0 events. Never executes anything.
    public func operationStatus(for key: OperationKey) throws(OperationStoreError) -> StatusOperation {
        guard let store else { throw .unavailable }
        if let live = sectionView(of: key) { return .found(live) }
        if let record = try store.record(for: key, now: seams.state.snapshot().reading.wall) {
            return .found(record.view)
        }
        return .notFound
    }

    /// Posts the releases the ledger still owes, if cleanup is authorized (contract 11.2, 12.8):
    /// after an abort whose releases had to wait, a failed release, or a start with entries left.
    /// Only while no call is in the admission section, so it never releases a running operation's
    /// input.
    public func releaseOwedInput() -> OwedRelease {
        guard section.isIdle else { return .operationInSection }
        let owed = ledger.pending()
        guard !owed.isEmpty else { return .nothingOwed }
        let state = seams.state
        let outcome = seams.releases.release(
            owed, from: &ledger, poster: seams.poster, authorization: { state.snapshot().cleanupAuthorization })
        seams.observer.cleanupPendingDidChange(!ledger.pending().isEmpty)
        return .attempted(outcome)
    }

    /// Loads the record file again after a failed write, and reads the ledger again, while no call
    /// is in the admission section (contract 12.3). Returns ``storesAvailable``.
    @discardableResult
    public func reloadUnavailableStores() -> Bool {
        guard section.isIdle else { return storesAvailable }
        if !(store?.isAvailable ?? false) {
            store = try? seams.operationStore.load(now: seams.state.snapshot().reading.wall)
        }
        if !ledger.isAvailable { try? ledger.reload() }
        seams.observer.cleanupPendingDidChange(!ledger.pending().isEmpty)
        return storesAvailable
    }

    /// The record's view for the `operation` member of a refusal at steps 1 to 4 (contract 9.5), with
    /// the live count while that operation executes.
    func recordView(_ key: OperationKey, at snapshot: DeskSnapshot) -> OperationView? {
        if case .executing(let claim, _, let posted) = section, claim.key == key {
            return OperationView(status: .executing, eventsPosted: posted)
        }
        return (try? store?.record(for: key, now: snapshot.reading.wall))?.view
    }

    /// The call inside the section, as a lookup of its key sees it: `accepted` with 0 events while it
    /// is being admitted, its live count once it executes.
    func sectionView(of key: OperationKey) -> OperationView? {
        switch section {
        case .admitting(let claim) where claim.key == key: OperationView(status: .accepted, eventsPosted: 0)
        case .executing(let claim, _, let posted) where claim.key == key:
            OperationView(status: .executing, eventsPosted: posted)
        default: nil
        }
    }

    /// Leaves the admission section: after a refusal, a replay or the final record write.
    func leaveSection() {
        let wasExecuting: Bool
        if case .executing = section { wasExecuting = true } else { wasExecuting = false }
        section = .idle
        interruption = nil
        if wasExecuting { seams.observer.executionDidChange(executing: false) }
        seams.observer.cleanupPendingDidChange(!ledger.pending().isEmpty)
    }

    /// Commits a refusal entry, best effort (contract 12.10).
    func logRefusal(_ entry: ActionLogRefusal?) async {
        guard let entry else { return }
        do {
            try await seams.log.commitRefusal(entry)
            seams.observer.actionLogDidAppend(succeeded: true)
        } catch {
            seams.observer.actionLogDidAppend(succeeded: false)
        }
    }

    /// `user_active` before admission, at the last look, before every event and at every poll
    /// (contract 13.2): input within `USER_ACTIVITY_LOOKBACK_MS`, or an idle signal that cannot be read.
    func activityCause() -> ToolErrorReason? {
        guard let idle = seams.activity.idleMilliseconds() else { return .userActive(idleMs: 0) }
        return idle < ContractConstants.userActivityLookbackMs ? .userActive(idleMs: max(0, idle)) : nil
    }
}
