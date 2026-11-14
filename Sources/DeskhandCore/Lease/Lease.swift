/// Whom a lease belongs to. Like every handle it is keyed by (principal, `holder_id`) (contract 4),
/// so the same `holder_id` under another principal is another holder.
public struct LeaseHolder: Hashable, Sendable, CustomStringConvertible {
    public let principal: Principal
    public let holderID: HolderID

    public init(principal: Principal, holderID: HolderID) {
        self.principal = principal
        self.holderID = holderID
    }

    public var description: String { "\(holderID) (\(principal))" }
}

/// One acquisition of the lease. A renewal moves `expiresAt` and keeps everything else.
public struct Lease: Hashable, Sendable {
    public let holder: LeaseHolder
    /// Differs between acquisitions, also by the same holder. An effect compares it with the lease
    /// it was admitted under, so a release followed by a new `acquire` between two checks still
    /// ends that effect (contract 5.3).
    public let serial: UInt64
    public let acquiredAt: Timestamp
    public internal(set) var expiresAt: Timestamp

    /// The lease runs out at `expiresAt`, not after it.
    public func isLive(at now: Timestamp) -> Bool { now < expiresAt }

    /// `expires_in_ms`: never negative.
    public func remainingMs(at now: Timestamp) -> Int {
        Int(max(0, expiresAt.millisecondsSinceEpoch - now.millisecondsSinceEpoch))
    }
}

/// The lease of this Mac (contract 5). There is at most one, so one holder drives the desktop.
public enum LeaseState: Hashable, Sendable {
    /// No lease is live, and `lease_expired` applies to nobody: no lease since the start, or the
    /// most recent one was released or dropped by `gated`, `paused` or `disarmed`.
    case none
    case held(Lease)
    /// No lease is live and the most recent one ran out. Its holder's effect calls get
    /// `lease_expired` until anyone acquires (contract 5.3, Appendix A item 23).
    case expired(last: Lease)
}

/// Why a live lease ended. Ending by another holder's `acquire` cannot happen: a live lease
/// refuses it.
public enum LeaseEndCause: Hashable, Sendable {
    case expired
    case released
    /// `gated`, `paused` or `disarmed` began (contract 10.4).
    case dropped(BlockingState)

    /// The code an effect executing under the ended lease is aborted with (contract 5.3, 13.1).
    public var abortReason: ToolErrorReason {
        switch self {
        case .expired: .leaseExpired
        case .released: .leaseNotHeld
        case .dropped(let state): .blocked(state)
        }
    }
}

/// A live lease that has just ended, for whoever must abort the effect executing under it.
public struct LeaseEnd: Hashable, Sendable {
    public let lease: Lease
    public let cause: LeaseEndCause
}

/// Why an effect call does not hold the lease (contract 9.5 step 5). Each case is one tool error.
public enum LeaseDenial: Error, Hashable, Sendable {
    case notHeld
    case heldByOther(expiresInMs: Int)
    case expired

    public var reason: ToolErrorReason {
        switch self {
        case .notHeld: .leaseNotHeld
        case .heldByOther(let expiresInMs): .leaseHeldByOther(expiresInMs: expiresInMs)
        case .expired: .leaseExpired
        }
    }

    /// For people and models; not stable.
    public var message: String {
        switch self {
        case .notHeld: "The named holder does not hold the lease. Acquire it with status."
        case .heldByOther: "Another holder holds the lease."
        case .expired: "The named holder's lease ran out. Acquire it again with status."
        }
    }
}
