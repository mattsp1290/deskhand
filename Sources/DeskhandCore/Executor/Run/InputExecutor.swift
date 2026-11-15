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
        /// The contract bounds none of these waits, so this is deskhand's own choice: long enough
        /// that a writer committing with a slow flush is not taken for a dead one, short enough that
        /// a hung writer or capture holds the section, and refuses every other effect with `busy`,
        /// for seconds rather than for ever.
        public static let defaultWaitLimit: Duration = .seconds(5)

        /// `ACTIONS_PER_MINUTE`.
        public var actionsPerMinute: Int
        /// How long the executor waits for an append to the action log, the frame check of step 9
        /// and the patch recapture of step 13 (contract 9.5, 12.3). An intent the writer has not
        /// acknowledged by then is `log_unavailable`, a recapture that has not answered is
        /// `stale_frame` `pixels_changed`, and an outcome or refusal entry counts as not written
        /// until the writer answers (contract 11.3).
        public var waitLimit: Duration

        public init(
            actionsPerMinute: Int = ContractConstants.defaultActionsPerMinute, waitLimit: Duration = defaultWaitLimit
        ) {
            self.actionsPerMinute = actionsPerMinute
            self.waitLimit = waitLimit
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
        /// Measures ``Configuration/waitLimit``.
        public var waitTimer: any WaitLimitTimer
        public var releases: any ReleaseHandler
        public var observer: any ExecutorObserver
        public var operationStore: any OperationStoreLoader

        public init(
            state: any StateSource, frames: any FrameSource, patches: any TargetPatchVerifier,
            identity: any IdentityMeasurer, activity: any UserActivitySource, poster: any EventPoster,
            keyCodes: any KeyCodeMapper, log: any ActionLogClient, timer: any ExecutionTimer = TaskSleepTimer(),
            waitTimer: any WaitLimitTimer = TaskSleepTimer(), releases: any ReleaseHandler = HeldInputReleaser(),
            observer: any ExecutorObserver, operationStore: any OperationStoreLoader
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
            self.waitTimer = waitTimer
            self.releases = releases
            self.observer = observer
            self.operationStore = operationStore
        }
    }

    let seams: Seams
    let waitLimit: WaitLimit
    var ceiling: ActionCeiling
    var store: OperationStore?
    var ledger: HeldInputLedger
    var pendingCleanup = PendingCleanup()
    var section: AdmissionSection = .idle
    var interruptions = PendingInterruptions()
    var logAttempts = ActionLogAttempts()

    var stopRequested = false

    var callsAnswering = 0
    var stopWaiters: [StopWaiter] = []

    var stoppedOperation: StoppedOperation?

    var stoppedOutcomeLogged = false

    var refusalsHeld = 0
    var outstandingRead: OutstandingRead?

    /// Loads the operation store, which applies the restart rules (contract 12.9), and takes the
    /// ledger as the previous run left it: any entry is owed a release, and a ledger that could not
    /// be read may hold some.
    public init(
        configuration: Configuration = Configuration(), seams: Seams, ledger: consuming sending HeldInputLedger,
        now: Timestamp
    ) {
        let owesReleases = !ledger.pending().isEmpty || !ledger.isAvailable
        self.seams = seams
        waitLimit = WaitLimit(duration: configuration.waitLimit, timer: seams.waitTimer)
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

    /// `cleanup_pending` (contract 11.2): no operation executes, and the ledger holds entries or
    /// cannot be read, in which case it may hold some.
    public var owesReleases: Bool { section.isIdle && ledgerOwes }

    var ledgerOwes: Bool { !ledger.pending().isEmpty || !ledger.isAvailable }

    /// Stops the call in the admission section with `interruption` at its next check: before its
    /// next event, or within one activity poll while it waits (contract 13). A call that has not
    /// reached its last look stops there. When several apply, the one first in the order of
    /// contract 9.5 wins; the end of a lease the call does not run under is kept but never applies.
    /// Ignored while the section is empty.
    public func interrupt(_ interruption: Interruption) {
        guard !section.isIdle else { return }
        interruptions.add(interruption)
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

    /// The record for `key`, with the live count while it executes: what the `operation` member of
    /// an error other than `operation_in_progress` and `operation_id_conflict` describes (contract
    /// 9.2). `nil` while a call with that key is still being admitted, since it has no record yet.
    public func recordedOperation(for key: OperationKey) -> OperationView? {
        recordView(key, at: seams.state.snapshot())
    }

    /// Loads the record file again after a failed write, and reads the ledger again, while no call
    /// is in the admission section (contract 12.3). Returns ``storesAvailable``.
    @discardableResult
    public func reloadUnavailableStores() -> Bool {
        guard section.isIdle else { return storesAvailable }
        reloadUnavailableRecords(now: seams.state.snapshot().reading.wall)
        if !ledger.isAvailable { try? ledger.reload() }
        seams.observer.cleanupPendingDidChange(ledgerOwes)
        return storesAvailable
    }

    func reloadUnavailableRecords(now: Timestamp) {
        guard !(store?.isAvailable ?? false) else { return }
        store = try? seams.operationStore.load(now: now)
    }

    func recordView(_ key: OperationKey, at snapshot: DeskSnapshot) -> OperationView? {
        if case .executing(let claim, _, let posted) = section, claim.key == key {
            return OperationView(status: .executing, eventsPosted: posted)
        }
        return (try? store?.record(for: key, now: snapshot.reading.wall))?.view
    }

    func sectionView(of key: OperationKey) -> OperationView? {
        switch section {
        case .admitting(let claim) where claim.key == key: OperationView(status: .accepted, eventsPosted: 0)
        case .executing(let claim, _, let posted) where claim.key == key:
            OperationView(status: .executing, eventsPosted: posted)
        default: nil
        }
    }

    func leaveSection() {
        let wasExecuting: Bool
        if case .executing = section { wasExecuting = true } else { wasExecuting = false }
        section = .idle
        interruptions = PendingInterruptions()
        if wasExecuting { seams.observer.executionDidChange(executing: false) }
        seams.observer.cleanupPendingDidChange(ledgerOwes)
        resumeStopWaiters()
    }

    func logRefusal(_ entry: ActionLogRefusal?, after intent: PendingIntent? = nil) async {
        guard let entry else { return }
        if let intent, intent.holdRefusal(entry) {
            refusalsHeld += 1
            return
        }
        let log = seams.log
        await logAppend { () async -> Void? in
            do throws(ActionLogFailure) {
                return try await log.commitRefusal(entry)
            } catch {
                return nil
            }
        }
    }

    func logHeldRefusal(_ entry: ActionLogRefusal) async {
        await logRefusal(entry)
        refusalsHeld -= 1
        resumeStopWaiters()
    }

    @discardableResult
    func logAppend<T: Sendable>(_ append: @escaping @Sendable () async -> T?) async -> T? {
        let attempt = logAttempts.start()
        let answer = await awaitBounded(within: waitLimit, append) { late in
            await self.reportLogAppend(attempt, succeeded: late != nil, answered: true)
        }
        guard let answer else {
            reportLogAppend(attempt, succeeded: false, answered: false)
            return nil
        }
        reportLogAppend(attempt, succeeded: answer != nil, answered: true)
        return answer
    }

    private func reportLogAppend(_ attempt: Int, succeeded: Bool, answered: Bool) {
        guard logAttempts.decides(attempt, answered: answered) else { return }
        seams.observer.actionLogDidAppend(succeeded: succeeded)
    }

    func activityCause() -> ToolErrorReason? {
        guard let idle = seams.activity.idleMilliseconds() else { return .userActive(idleMs: 0) }
        return idle < ContractConstants.userActivityLookbackMs ? .userActive(idleMs: max(0, idle)) : nil
    }
}
