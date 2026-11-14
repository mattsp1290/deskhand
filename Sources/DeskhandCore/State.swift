/// A deskhand state (contract 10). Declaration order is precedence, highest first, and `<` follows
/// it: `gated < paused < … < ok`, so the state in force is the `min()` of those that hold.
public enum DeskhandState: String, CaseIterable, Comparable, Sendable {
    case gated, paused, disarmed
    case notConsole = "not_console"
    case locked
    case displayAsleep = "display_asleep"
    case permissionMissing = "permission_missing"
    case permissionStale = "permission_stale"
    case secureInput = "secure_input"
    case ok

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// The same state as a ``BlockingState``, or `nil` for `ok`.
    public var blocking: BlockingState? { BlockingState(rawValue: rawValue) }
}

/// Every state but `ok` (`defs.json#/$defs/blocking_state`): the states that refuse every tool but
/// `status` with their own name. Ordered by precedence like ``DeskhandState``.
public enum BlockingState: String, CaseIterable, Comparable, Sendable {
    case gated, paused, disarmed
    case notConsole = "not_console"
    case locked
    case displayAsleep = "display_asleep"
    case permissionMissing = "permission_missing"
    case permissionStale = "permission_stale"
    case secureInput = "secure_input"

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.state < rhs.state }

    public var state: DeskhandState { DeskhandState(rawValue: rawValue)! }

    /// `gated`, `paused` and `disarmed` drop the lease when they begin and refuse `acquire`/`renew`.
    public var dropsLease: Bool { leaseDropping != nil }

    /// The same state as a ``LeaseDroppingState``, or `nil` when it leaves the lease alone.
    public var leaseDropping: LeaseDroppingState? { LeaseDroppingState(rawValue: rawValue) }
}

/// The three states that drop the lease when they begin and refuse `acquire` and `renew` while they
/// hold (contract 5.2, 10.4). Ordered by precedence like ``BlockingState``.
public enum LeaseDroppingState: String, CaseIterable, Comparable, Sendable {
    case gated, paused, disarmed

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.blocking < rhs.blocking }

    public var blocking: BlockingState { BlockingState(rawValue: rawValue)! }
}

/// The set of states that hold now. `state` and `active_states` of `status` both derive from it,
/// so they cannot disagree.
public struct ActiveStates: Hashable, Sendable {
    public let states: Set<BlockingState>

    public init(_ states: some Sequence<BlockingState>) { self.states = Set(states) }

    public static let none = ActiveStates([])

    /// The state with the highest precedence, `ok` when nothing blocks.
    public var current: DeskhandState { states.min()?.state ?? .ok }

    /// `status.active_states`: highest precedence first.
    public var inPrecedenceOrder: [BlockingState] { states.sorted() }
}

/// A condition reported in `status.conditions` that is not a state (contract 11).
public enum Condition: String, CaseIterable, Sendable {
    case credentialsWarning = "credentials_warning"
    case cleanupPending = "cleanup_pending"
    case logUnavailable = "log_unavailable"
    case loginWindow = "login_window"
    case userActive = "user_active"
}
