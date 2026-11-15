/// A condition that holds back every release, the releases of an ordinary abort and of restart
/// cleanup alike (contract 12.8). Each is judged on its own, whatever state `status` reports.
public enum CleanupBlocker: String, CaseIterable, Hashable, Sendable {
    case locked
    case notConsole = "not_console"
    case loginWindow = "login_window"
    case secureInput = "secure_input"

    private enum Signal {
        case state(BlockingState)
        case condition(Condition)
    }

    private var signal: Signal {
        switch self {
        case .locked: .state(.locked)
        case .notConsole: .state(.notConsole)
        case .loginWindow: .condition(.loginWindow)
        case .secureInput: .state(.secureInput)
        }
    }

    fileprivate func holds(in active: ActiveStates, conditions: Set<Condition>) -> Bool {
        switch signal {
        case .state(let state): active.states.contains(state)
        case .condition(let condition): conditions.contains(condition)
        }
    }
}

/// Whether deskhand may post releases now (contract 12.8).
public enum CleanupAuthorization: Hashable, Sendable {
    case authorized
    /// Releases wait in the ledger until every one of these has ended.
    case deferred(Set<CleanupBlocker>)

    /// Every ``CleanupBlocker`` must be absent. `gated`, `paused`, `disarmed`, `display_asleep`, the
    /// permission states and `user_active` do not block, because a release removes input.
    public init(active: ActiveStates, conditions: Set<Condition>) {
        let blockers = Set(CleanupBlocker.allCases.filter { $0.holds(in: active, conditions: conditions) })
        self = blockers.isEmpty ? .authorized : .deferred(blockers)
    }

    public var isAuthorized: Bool { self == .authorized }
}
