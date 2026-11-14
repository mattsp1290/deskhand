/// The lease rules of contract section 5 over the one ``LeaseState`` of this Mac.
///
/// A value with no clock of its own: the server's state owner keeps the single instance, serializes
/// every call to it and passes `now`. A restart starts from a new instance, which is how a restart
/// ends the lease and forgets `lease_expired`.
public struct LeaseManager: Hashable, Sendable {
    /// As last written. A held lease whose expiry has passed is still `held` here until a mutating
    /// call or ``expire(now:)`` settles it; ``state(at:)`` gives the state as of a given instant.
    public private(set) var lease: LeaseState = .none
    private var lastSerial: UInt64 = 0

    public init() {}

    /// The state as of `now`: a held lease whose expiry has passed has run out.
    public func state(at now: Timestamp) -> LeaseState {
        guard case .held(let held) = lease, !held.isLive(at: now) else { return lease }
        return .expired(last: held)
    }

    /// When the held lease runs out, for the deadline watchdog (contract 13.1). `nil` while no lease
    /// is held. At this instant the watchdog calls ``expire(now:)``.
    public var deadline: Timestamp? {
        guard case .held(let held) = lease else { return nil }
        return held.expiresAt
    }

    /// Ends the held lease if it has run out by `now`.
    public mutating func expire(now: Timestamp) -> LeaseEnd? {
        guard case .held(let held) = lease, !held.isLive(at: now) else { return nil }
        lease = .expired(last: held)
        return LeaseEnd(lease: held, cause: .expired)
    }

    /// Runs a `status` call's `lease` argument (contract 5.1, 5.2). A refusal is an outcome, not an
    /// error. `state` is the state in force: `acquire` and `renew` are refused with its name while it
    /// is `gated`, `paused` or `disarmed`, and `release` is allowed in every state.
    public mutating func apply(
        _ request: LeaseRequest, principal: Principal, state: DeskhandState, now: Timestamp
    ) -> LeaseResult {
        _ = expire(now: now)
        let caller = LeaseHolder(principal: principal, holderID: request.holderID)
        let outcome: LeaseOutcome
        switch (request.operation, state.blocking) {
        case (.acquire, let blocking?) where blocking.dropsLease, (.renew, let blocking?) where blocking.dropsLease:
            outcome = .refused(LeaseRefusal(rawValue: blocking.rawValue)!)
        case (.acquire, _):
            outcome = acquire(by: caller, ttlMs: request.ttlMs, now: now)
        case (.renew, _):
            outcome = renew(by: caller, ttlMs: request.ttlMs, now: now)
        case (.release, _):
            outcome = release(by: caller)
        }
        return LeaseResult(operation: request.operation, outcome: outcome)
    }

    /// The lease check of an effect call (contract 9.5 step 5), also run before every posted event
    /// of an admitted one. Returns the live lease the holder holds.
    public func check(principal: Principal, holderID: HolderID, now: Timestamp) throws(LeaseDenial) -> Lease {
        let caller = LeaseHolder(principal: principal, holderID: holderID)
        switch state(at: now) {
        case .held(let held) where held.holder == caller: return held
        case .held(let held): throw .heldByOther(expiresInMs: held.remainingMs(at: now))
        case .expired(let last) where last.holder == caller: throw .expired
        case .expired, .none: throw .notHeld
        }
    }

    /// Drops the lease because `gated`, `paused` or `disarmed` began (contract 10.4). A lease that
    /// had already run out by `now` is not dropped: it stays expired, so its holder still gets
    /// `lease_expired`.
    public mutating func drop(because state: BlockingState, now: Timestamp) -> LeaseEnd? {
        precondition(state.dropsLease, "\(state) does not drop the lease")
        guard expire(now: now) == nil, case .held(let held) = lease else { return nil }
        lease = .none
        return LeaseEnd(lease: held, cause: .dropped(state))
    }

    /// `status.lease` as `principal` may see it (contract 5.4): `nil` while no lease is live, and
    /// `holder_id` only for the principal that holds it.
    public func view(for principal: Principal, now: Timestamp) -> LeaseView? {
        guard case .held(let held) = state(at: now) else { return nil }
        return LeaseView(
            holderID: held.holder.principal == principal ? held.holder.holderID : nil,
            acquiredAt: held.acquiredAt, expiresAt: held.expiresAt, expiresInMs: held.remainingMs(at: now)
        )
    }

    private mutating func acquire(by caller: LeaseHolder, ttlMs: Int, now: Timestamp) -> LeaseOutcome {
        switch lease {
        case .held(let held) where held.holder == caller:
            return extend(held, ttlMs: ttlMs, now: now)
        case .held:
            return .refused(.leaseHeldByOther)
        case .none, .expired:
            lastSerial += 1
            lease = .held(
                Lease(
                    holder: caller, serial: lastSerial, acquiredAt: now,
                    expiresAt: now.adding(milliseconds: Int64(ttlMs))
                )
            )
            return .acquired
        }
    }

    /// `renew` never acquires.
    private mutating func renew(by caller: LeaseHolder, ttlMs: Int, now: Timestamp) -> LeaseOutcome {
        switch lease {
        case .held(let held) where held.holder == caller: return extend(held, ttlMs: ttlMs, now: now)
        case .held: return .refused(.leaseHeldByOther)
        case .expired(let last) where last.holder == caller: return .refused(.leaseExpired)
        case .expired, .none: return .refused(.leaseNotHeld)
        }
    }

    /// Releasing with no live lease is a no-op, so a repeated release is safe; it also leaves an
    /// expired lease's `lease_expired` in place.
    private mutating func release(by caller: LeaseHolder) -> LeaseOutcome {
        switch lease {
        case .held(let held) where held.holder == caller:
            lease = .none
            return .released
        case .held: return .refused(.leaseHeldByOther)
        case .expired, .none: return .notHeld
        }
    }

    private mutating func extend(_ held: Lease, ttlMs: Int, now: Timestamp) -> LeaseOutcome {
        var renewed = held
        renewed.expiresAt = now.adding(milliseconds: Int64(ttlMs))
        lease = .held(renewed)
        return .renewed
    }
}
