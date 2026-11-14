extension InputExecutor {
    /// When ``retryCleanup(now:)`` is next due, never before `now`, for the watchdog to wake at.
    /// `nil` while nothing is owed: the ledger is empty, or a call is in the admission section and
    /// its own end releases what it pressed.
    public func nextCleanupRetry(at now: ClockReading) -> ContinuousClock.Instant? {
        guard owesReleases else { return nil }
        return pendingCleanup.schedule.nextRetry(at: now.monotonic, context: CleanupContext(seams.state.snapshot()))
    }

    /// The retry of contract 11.2: posts the releases the ledger still owes, if cleanup is
    /// authorized, when a retry is due at `now`. Call it on every change of state and at least once
    /// a second; it tries at once after a change of state or of the blocking conditions, and
    /// otherwise a second after the last attempt. `nil` when no retry is due yet. Restart cleanup is
    /// the first retry after ``init(configuration:seams:ledger:now:)``, which is due at once
    /// (contract 12.9 step 5).
    ///
    /// A ledger that a failed write left unavailable is read again first; until it can be written,
    /// every effect is refused with `internal_error` and the entries stay owed.
    public func retryCleanup(now: ClockReading) -> OwedRelease? {
        guard section.isIdle else { return .operationInSection }
        guard !ledger.pending().isEmpty else {
            pendingCleanup.reset()
            return .nothingOwed
        }
        let context = CleanupContext(seams.state.snapshot())
        guard pendingCleanup.schedule.isDue(at: now.monotonic, context: context) else { return nil }
        return .attempted(releaseOwed(context: context, at: now.monotonic))
    }

    /// Posts the releases the ledger still owes, if cleanup is authorized, whether or not a retry is
    /// due (contract 11.2, 12.8): after an abort whose releases had to wait, a failed release, or a
    /// start with entries left. Only while no call is in the admission section, so it never
    /// releases a running operation's input.
    public func releaseOwedInput() -> OwedRelease {
        guard section.isIdle else { return .operationInSection }
        guard !ledger.pending().isEmpty else { return .nothingOwed }
        let snapshot = seams.state.snapshot()
        return .attempted(releaseOwed(context: CleanupContext(snapshot), at: snapshot.reading.monotonic))
    }

    /// Contract 12.4 step 2 for the operation that is ending: releases what it pressed and has not
    /// let up, newest first, if cleanup is authorized. Otherwise they wait in the ledger, and
    /// leaving the section reports `cleanup_pending`.
    func releaseOperationInput(_ pressed: [HeldInput]) {
        let state = seams.state
        let snapshot = state.snapshot()
        _ = pendingCleanup.releaseOperation(
            pressed, from: &ledger, through: seams.releases, poster: releasePoster(),
            authorization: { state.snapshot().cleanupAuthorization }, context: CleanupContext(snapshot),
            at: snapshot.reading.monotonic)
    }

    private func releaseOwed(context: CleanupContext, at instant: ContinuousClock.Instant) -> CleanupOutcome {
        let state = seams.state
        let outcome = pendingCleanup.releaseOwed(
            from: &ledger, through: seams.releases, poster: releasePoster(),
            authorization: { state.snapshot().cleanupAuthorization }, context: context, at: instant)
        seams.observer.cleanupPendingDidChange(!ledger.pending().isEmpty)
        return outcome
    }

    /// The poster a release handler gets, which tells the observer of every release it posts, at
    /// the time it went out.
    private func releasePoster() -> ReleaseOnlyPoster {
        let (state, observer) = (seams.state, seams.observer)
        return ReleaseOnlyPoster(seams.poster) { observer.didPostEvent(at: state.snapshot().reading.monotonic) }
    }
}
