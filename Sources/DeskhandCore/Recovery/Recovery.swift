/// Builds what deskhand runs on when it starts, before it answers any call (contract 12.9), in one
/// fixed order:
///
/// 1. The in-memory world: no frame, no lease, `disarmed` and not `paused`, a new `started_at`
///    (``StartupWorld``). The caller builds the owners of the state, the lease and the frames from
///    it, and the executor's seams on those owners.
/// 2. The held-input ledger, as the previous run left it.
/// 3. The operation records, through the seams' ``InputExecutor/Seams/operationStore``: `accepted`
///    becomes `failed_before_execution` and `executing` becomes `aborted_by_restart`, durably.
/// 4. The first attempt at the releases the ledger holds, posted only if cleanup is authorized
///    (contract 12.8). Otherwise they stay owed, `cleanup_pending` refuses every effect, and the
///    retries of ``InputExecutor/retryCleanup(now:)`` post them once cleanup is authorized.
///
/// A store that cannot be loaded (a corrupt journal, an unreadable ledger, a file or directory with
/// the wrong owner or mode) fails closed: the executor refuses every effect with `internal_error`,
/// and reports `cleanup_pending` while the ledger is unread, until a read succeeds. Each retry of
/// ``InputExecutor/retryCleanup(now:)``, at least once a second, reads it again, and then posts
/// what it owes; ``InputExecutor/reloadUnavailableStores()`` does so at once. `status` still
/// answers, and the report says why. The file is left as it is, never taken for an empty one.
///
/// Every step converges when repeated: the restart rules leave a final record alone, and a ledger
/// entry is cleared only after its release went out. Recovering again, also after a crash part-way
/// through, ends with the same records and an empty ledger; at worst a release is posted twice,
/// which does no harm (contract 12.7).
public struct Recovery: Sendable {
    public let configuration: InputExecutor.Configuration
    /// Where the held-input ledger lives (contract 12.7).
    public let ledgerStore: any HeldInputStore & Sendable

    public init(ledgerStore: any HeldInputStore & Sendable, configuration: InputExecutor.Configuration = .init()) {
        self.ledgerStore = ledgerStore
        self.configuration = configuration
    }

    /// Recovers the stores and returns the executor with the world it was built on.
    ///
    /// - Parameters:
    ///   - now: The start. `started_at` is its wall time.
    ///   - makeSeams: Builds the executor's seams on owners seeded from the world. Their
    ///     `operationStore` loads the record file; ``FileOperationStoreLoader`` is the real one.
    public func start(
        at now: ClockReading, isolation: isolated (any Actor)? = #isolation,
        seams makeSeams: (StartupWorld) -> InputExecutor.Seams
    ) async -> RecoveredStart {
        let world = StartupWorld(startedAt: now.wall)
        var seams = makeSeams(world)
        let records = StartLoadRecorder(seams.operationStore)
        seams.operationStore = records

        let ledger: HeldInputLedger
        let ledgerRecovery: HeldInputLedgerRecovery
        do throws(HeldInputLedgerError) {
            ledger = try HeldInputLedger(store: ledgerStore)
            ledgerRecovery = .loaded(left: ledger.pending())
        } catch {
            ledger = HeldInputLedger(unreadable: ledgerStore)
            ledgerRecovery = .unavailable(error)
        }

        let executor = InputExecutor(configuration: configuration, seams: seams, ledger: ledger, now: now.wall)
        let cleanup = await executor.releaseOwedInput()
        let effectRefusal: ToolErrorCode? =
            if await !executor.storesAvailable {
                .internalError
            } else if await executor.owesReleases {
                .cleanupPending
            } else {
                nil
            }
        let report = RecoveryReport(
            // The executor's initializer loads the store once, synchronously.
            operationRecords: records.firstLoad!, heldInputLedger: ledgerRecovery, cleanup: cleanup,
            effectRefusal: effectRefusal)
        return RecoveredStart(executor: executor, world: world, report: report)
    }
}

/// What ``Recovery/start(at:isolation:seams:)`` built.
public struct RecoveredStart: Sendable {
    /// Ready: it admits an effect once the state is `ok`, no release is owed and both stores are
    /// available.
    public let executor: InputExecutor
    public let world: StartupWorld
    public let report: RecoveryReport
}
