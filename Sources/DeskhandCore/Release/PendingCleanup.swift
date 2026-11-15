import Synchronization

struct PendingCleanup {
    private(set) var schedule = CleanupRetrySchedule()
    private var postedUncleared: Set<HeldInput> = []

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

    mutating func settle(owed: Bool, context: CleanupContext, at instant: ContinuousClock.Instant) {
        if owed {
            schedule.didAttempt(at: instant, context: context)
        } else {
            reset()
        }
    }
}

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

    var released: [HeldInput] { posted.withLock { $0 } }

    func post(_ event: InputEvent) throws { throw NotARelease(event: event) }

    func postRelease(_ input: HeldInput) throws {
        try poster.postRelease(input)
        posted.withLock { $0.append(input) }
        didRelease()
    }
}
