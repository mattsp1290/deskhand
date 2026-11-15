import Synchronization

/// What the executor remembers between its attempts at the releases it owes (contract 11.2, 12.7,
/// 12.8): when to try again, and which releases already went out. The executor keeps the one value
/// and serializes every call to it, lending it the ledger for the call.
struct PendingCleanup {
    private(set) var schedule = CleanupRetrySchedule()
    /// Inputs whose release went out but whose entry the ledger could not clear. Nothing has pressed
    /// them since, because no operation starts while the ledger holds entries, so a retry only
    /// clears them and does not post them again every second while the disk refuses writes. A
    /// restart forgets this, and the entries' releases are then posted again, which does no harm.
    private var postedUncleared: Set<HeldInput> = []

    /// An operation's own releases as it ends (contract 12.4 step 2): what it pressed and has not
    /// let up. `nil` when it holds nothing. The operation started on an empty ledger, so nothing
    /// remembered from before it still applies.
    mutating func releaseOperation(
        _ pressed: [HeldInput], from ledger: inout HeldInputLedger, through handler: any ReleaseHandler,
        poster: ReleaseOnlyPoster, authorization: () -> CleanupAuthorization, context: CleanupContext,
        at instant: ContinuousClock.Instant
    ) -> CleanupOutcome? {
        reset()
        guard !pressed.isEmpty else { return nil }
        let outcome = post(pressed, from: &ledger, through: handler, poster: poster, authorization: authorization)
        settle(owed: !ledger.pending().isEmpty || !ledger.isAvailable, context: context, at: instant)
        return outcome
    }

    /// Every entry the ledger holds, newest first: releases that had to wait or failed, and restart
    /// cleanup (contract 12.7 item 5, 12.9 step 5). A ledger that could not be read, or that a
    /// failed write left unavailable, is read again first. An entry whose release already went out
    /// is only cleared. `nil` when the ledger holds no entry, or could not be read and knows none.
    /// The caller then records the attempt with ``settle(owed:context:at:)``.
    mutating func releaseOwed(
        from ledger: inout HeldInputLedger, through handler: any ReleaseHandler, poster: ReleaseOnlyPoster,
        authorization: () -> CleanupAuthorization
    ) -> CleanupOutcome? {
        if !ledger.isAvailable { try? ledger.reload() }
        guard !ledger.pending().isEmpty else {
            postedUncleared = []
            return nil
        }
        postedUncleared.formIntersection(ledger.pending())
        var clearFailure: HeldInputLedgerError?
        for input in ledger.pending().reversed() where postedUncleared.contains(input) {
            do {
                try ledger.didRelease(input)
                postedUncleared.remove(input)
            } catch {
                clearFailure = clearFailure ?? error
            }
        }
        let unposted = ledger.pending().filter { !postedUncleared.contains($0) }
        var outcome: CleanupOutcome = ledger.isAvailable ? .complete : .clearFailed(.unavailable)
        if !unposted.isEmpty {
            outcome = post(unposted, from: &ledger, through: handler, poster: poster, authorization: authorization)
        }
        switch outcome {
        case .deferred, .postFailed: return outcome
        case .complete, .clearFailed: return clearFailure.map(CleanupOutcome.clearFailed) ?? outcome
        }
    }

    /// Nothing is owed: the next time something is, it is tried at once.
    mutating func reset() {
        schedule.reset()
        postedUncleared = []
    }

    private mutating func post(
        _ inputs: [HeldInput], from ledger: inout HeldInputLedger, through handler: any ReleaseHandler,
        poster: ReleaseOnlyPoster, authorization: () -> CleanupAuthorization
    ) -> CleanupOutcome {
        let before = poster.released.count
        let outcome = handler.release(inputs, from: &ledger, poster: poster, authorization: authorization)
        let pending = ledger.pending()
        postedUncleared.formUnion(poster.released.dropFirst(before).filter(pending.contains))
        return outcome
    }

    /// Records an attempt at `instant`. While something is still `owed` the next one is due a
    /// second later, or at once when the context changes; otherwise the next time something is
    /// owed it is tried at once.
    mutating func settle(owed: Bool, context: CleanupContext, at instant: ContinuousClock.Instant) {
        if owed {
            schedule.didAttempt(at: instant, context: context)
        } else {
            reset()
        }
    }
}

/// The poster as a release handler gets it: releases pass through and are counted, and anything
/// else is refused, because cleanup posts a key-up or a button-up and nothing else, and never moves
/// the pointer (contract 12.4, 12.8). ``didRelease`` runs after each release that went out: a
/// release is an event deskhand posted, which the arming lookback counts from (contract 10.4).
final class ReleaseOnlyPoster: EventPoster {
    struct NotARelease: Error, CustomStringConvertible {
        let event: InputEvent

        var description: String { "cleanup posts only releases, not \(event)" }
    }

    private let poster: any EventPoster
    private let didRelease: @Sendable () -> Void
    private let posted = Mutex<[HeldInput]>([])

    init(_ poster: any EventPoster, didRelease: @escaping @Sendable () -> Void) {
        self.poster = poster
        self.didRelease = didRelease
    }

    /// The releases that went out, in order.
    var released: [HeldInput] { posted.withLock { $0 } }

    func post(_ event: InputEvent) throws { throw NotARelease(event: event) }

    func postRelease(_ input: HeldInput) throws {
        try poster.postRelease(input)
        posted.withLock { $0.append(input) }
        didRelease()
    }
}
