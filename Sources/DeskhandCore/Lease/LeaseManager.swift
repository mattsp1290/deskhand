/// What one `lease` call did: the result it returns, and the live lease it ended, if any.
public struct LeaseApplication: Hashable, Sendable {
    public let result: LeaseToolResult
    /// The live lease this call ended: by settling an expiry that nobody had observed yet, or by
    /// `release`. The owner aborts the effect executing under it with `ended.cause.abortReason`
    /// (contract 5.3).
    public let ended: LeaseEnd?
}

/// The lease rules of contract section 5 over the one ``LeaseState`` of this Mac.
///
/// A value with no clock of its own: the server's state owner keeps the single instance, serializes
/// every call to it and passes the ``ClockReading``. Every way a live lease ends, by running out, by
/// `release` or by a state that drops it, is returned as a ``LeaseEnd`` from the call that settled
/// it, and the most recent ends are kept for ``endCause(of:now:)``. A restart starts from a new
/// instance, which is how a restart ends the lease and forgets `lease_expired`.
public struct LeaseManager: Hashable, Sendable {
    /// How many of the most recent ends ``endCause(of:now:)`` can name. An effect checks its lease
    /// before every event and at every activity poll, and the owner aborts it as soon as a call
    /// returns its lease's end, so this many further leases cannot end in between.
    public static let retainedEnds = 16

    /// As last written. A held lease whose deadline has passed is still `held` here until a mutating
    /// call or ``expire(now:)`` settles it; ``state(at:)`` gives the state as of a given reading.
    public private(set) var lease: LeaseState = .none
    private var recentEnds: [LeaseEnd] = []
    private var lastSerial: UInt64 = 0

    public init() {}

    /// The most recent end of a live lease.
    public var lastEnd: LeaseEnd? { recentEnds.last }

    /// The state as of `now`: a held lease whose deadline has passed has run out.
    public func state(at now: ClockReading) -> LeaseState {
        guard case .held(let held) = lease, !held.isLive(at: now) else { return lease }
        return .expired(last: held)
    }

    /// When the held lease runs out, for the deadline watchdog (contract 13.1). `nil` while no lease
    /// is held. At this instant the watchdog calls ``expire(now:)``; if a `lease` call settles the
    /// expiry first, that call's ``LeaseApplication/ended`` reports it instead.
    public var deadline: ContinuousClock.Instant? {
        guard case .held(let held) = lease else { return nil }
        return held.deadline
    }

    /// The deadline of `admitted` as it stands now, moved by every renewal since admission, or
    /// `nil` once `admitted` is no longer the held lease. Already past once it has run out.
    public func deadline(of admitted: Lease) -> ContinuousClock.Instant? {
        guard case .held(let held) = lease, held.serial == admitted.serial else { return nil }
        return held.deadline
    }

    /// Ends the held lease if it has run out by `now`.
    public mutating func expire(now: ClockReading) -> LeaseEnd? {
        guard case .held(let held) = lease, !held.isLive(at: now) else { return nil }
        lease = .expired(last: held)
        return ended(held, .expired)
    }

    /// Runs one `lease` call (contract 5.1, 5.2). A refusal is an outcome, not an error. `state` is
    /// the state in force: `acquire` and `renew` are refused with its name while it is `gated`,
    /// `paused` or `disarmed`, and `release` is allowed in every state.
    public mutating func apply(
        _ arguments: LeaseArguments, principal: Principal, state: DeskhandState, now: ClockReading
    ) -> LeaseApplication {
        let expiry = expire(now: now)
        var release: LeaseEnd?
        let caller = LeaseHolder(principal: principal, holderID: arguments.holderID)
        let outcome: LeaseOutcome
        switch (arguments.command, state.blocking?.leaseDropping) {
        case (.acquire, let dropping?), (.renew, let dropping?):
            outcome = .refused(.state(dropping))
        case (.acquire(let ttlMs), nil):
            outcome = acquire(by: caller, ttlMs: ttlMs, now: now)
        case (.renew(let ttlMs), nil):
            outcome = renew(by: caller, ttlMs: ttlMs, now: now)
        case (.release, _):
            (outcome, release) = self.release(by: caller, now: now)
        }
        let result = LeaseToolResult(
            result: LeaseResult(operation: arguments.operation, outcome: outcome), lease: view(for: caller, now: now))
        return LeaseApplication(result: result, ended: expiry ?? release)
    }

    /// The lease check of an effect call (contract 9.5 step 6). Returns the live lease the holder
    /// holds; the executor keeps it to name the lease it was admitted under, and runs
    /// ``endCause(of:now:)`` at the last look and before every later event. Its `deadline` is the
    /// one at admission: the current one is ``deadline(of:)``, which a renewal moves.
    public func check(principal: Principal, holderID: HolderID, now: ClockReading) throws(LeaseDenial) -> Lease {
        let caller = LeaseHolder(principal: principal, holderID: holderID)
        switch state(at: now) {
        case .held(let held) where held.holder == caller: return held
        case .held(let held): throw .heldByOther(expiresInMs: held.remainingMs(at: now))
        case .expired(let last) where last.holder == caller: throw .expired
        case .expired, .none: throw .notHeld
        }
    }

    /// The lease check of an admitted effect: one of the checks of the last look, immediately
    /// before the first event, and of every later event (contract 12.3 steps 5 and 6, 12.4, 13.1).
    /// `nil` while `admitted` is still the live lease, otherwise why it ended, which is the code the
    /// effect is aborted with (``LeaseEndCause/abortReason``); at the last look that abort has 0
    /// events. Leases acquired and ended after `admitted` do not change the answer. A lease that
    /// ended more than ``retainedEnds`` ends ago no longer holds either way and counts as released
    /// (`lease_not_held`).
    public func endCause(of admitted: Lease, now: ClockReading) -> LeaseEndCause? {
        if case .held(let held) = lease, held.serial == admitted.serial {
            return held.isLive(at: now) ? nil : .expired
        }
        if let end = recentEnds.last(where: { $0.lease.serial == admitted.serial }) { return end.cause }
        return .released
    }

    /// Drops the lease because `gated`, `paused` or `disarmed` began (contract 10.4). A lease that
    /// had already run out by `now` is not dropped: it stays expired, so its holder still gets
    /// `lease_expired`, and that expiry is what is returned.
    public mutating func drop(because state: LeaseDroppingState, now: ClockReading) -> LeaseEnd? {
        if let expiry = expire(now: now) { return expiry }
        guard case .held(let held) = lease else { return nil }
        lease = .none
        return ended(held, .dropped(state))
    }

    /// The lease as `holder` sees it (contract 5.4). Says nothing about any other holder.
    public func view(for holder: LeaseHolder, now: ClockReading) -> LeaseView {
        guard case .held(let held) = state(at: now), held.holder == holder else { return .notHeldByCaller }
        return .heldByCaller(
            acquiredAt: held.acquiredAt, expiresAt: held.expiresAt(at: now), expiresInMs: held.remainingMs(at: now))
    }

    private mutating func ended(_ lease: Lease, _ cause: LeaseEndCause) -> LeaseEnd {
        let end = LeaseEnd(lease: lease, cause: cause)
        recentEnds.append(end)
        if recentEnds.count > Self.retainedEnds { recentEnds.removeFirst() }
        return end
    }

    private mutating func acquire(by caller: LeaseHolder, ttlMs: Int, now: ClockReading) -> LeaseOutcome {
        switch lease {
        case .held(let held) where held.holder == caller:
            return extend(held, ttlMs: ttlMs, now: now)
        case .held(let held):
            return .refused(.leaseHeldByOther(expiresInMs: held.remainingMs(at: now)))
        case .none, .expired:
            lastSerial += 1
            lease = .held(
                Lease(
                    holder: caller, serial: lastSerial, acquiredAt: now.wall,
                    deadline: now.instant(afterMilliseconds: Int64(ttlMs))))
            return .acquired
        }
    }

    private mutating func renew(by caller: LeaseHolder, ttlMs: Int, now: ClockReading) -> LeaseOutcome {
        switch lease {
        case .held(let held) where held.holder == caller: return extend(held, ttlMs: ttlMs, now: now)
        case .held(let held): return .refused(.leaseHeldByOther(expiresInMs: held.remainingMs(at: now)))
        case .expired(let last) where last.holder == caller: return .refused(.leaseExpired)
        case .expired, .none: return .refused(.leaseNotHeld)
        }
    }

    private mutating func release(by caller: LeaseHolder, now: ClockReading) -> (LeaseOutcome, LeaseEnd?) {
        switch lease {
        case .held(let held) where held.holder == caller:
            lease = .none
            return (.released, ended(held, .released))
        case .held(let held): return (.refused(.leaseHeldByOther(expiresInMs: held.remainingMs(at: now))), nil)
        case .expired, .none: return (.notHeld, nil)
        }
    }

    private mutating func extend(_ held: Lease, ttlMs: Int, now: ClockReading) -> LeaseOutcome {
        var renewed = held
        renewed.deadline = now.instant(afterMilliseconds: Int64(ttlMs))
        lease = .held(renewed)
        return .renewed
    }
}
