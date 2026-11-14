/// The state deskhand reports, and the arming it carries into the next reduction. `status.state`,
/// `status.active_states` and `status.armed_until` come from here; `status.conditions` is
/// `conditions` plus `user_active`, which `status` evaluates when it is called (contract 11.5).
public struct StateReport: Hashable, Sendable {
    public let arming: Arming
    public let activeStates: ActiveStates
    /// Never contains `user_active`.
    public let conditions: Set<Condition>

    init(arming: Arming, signals: StateSignals) {
        var states = Set(arming.blockingStates)
        if !signals.allowanceValid { states.insert(.gated) }
        for signal in PlatformSignal.allCases where signals[signal].holds { states.insert(signal.feeds) }
        var conditions: Set<Condition> = []
        if signals.credentialsWarning { conditions.insert(.credentialsWarning) }
        if signals.cleanupPending { conditions.insert(.cleanupPending) }
        if signals.logUnavailable { conditions.insert(.logUnavailable) }
        if signals[.loginWindow].holds { conditions.insert(.loginWindow) }
        self.arming = arming
        self.activeStates = ActiveStates(states)
        self.conditions = conditions
    }

    public var state: DeskhandState { activeStates.current }

    public var armedUntil: Timestamp? { arming.armedUntil }

    /// The report before anything has been read: `disarmed`, as every start is, and every state that
    /// a missing reading makes hold. Seed the first ``StateReducer/reduce(previous:signals:command:now:)``
    /// with it.
    public static let startup = StateReport(arming: .disarmed, signals: .unread)
}

/// Work a change of state requires. Effects are data; the caller carries them out in list order.
public enum TransitionEffect: Hashable, Sendable {
    /// Abort the executing effect, refuse every `displays` and `screenshot` call that has not
    /// answered, and discard a screenshot captured but not returned, all with this state's name
    /// (contract 10.3 step 1).
    case cancelInFlight(BlockingState)
    /// Release what the aborted effect held, if cleanup is authorized (contract 10.3 step 2, 12.8).
    case releaseHeldInput
    /// Invalidate every frame of every holder (contract 10.3 step 3).
    case invalidateFrames
    /// `gated`, `paused` or `disarmed` began (contract 10.4).
    case dropLease
}

/// One owner keeps the latest ``StateReport``, feeds it back as `previous` and serializes the
/// reductions, so that no transition and none of its effects is skipped.
public enum StateReducer {
    /// The report for `signals` at `now`, after `command` if a person issued one, and the effects of
    /// the change from `previous`. Pure: the same arguments always give the same result.
    public static func reduce(
        previous: StateReport, signals: StateSignals, command: ArmingCommand? = nil, now: Timestamp
    ) -> (report: StateReport, effects: [TransitionEffect]) {
        let report = StateReport(arming: previous.arming.applying(command, now: now), signals: signals)
        return (report, effects(from: previous.activeStates, to: report.activeStates))
    }

    private static func effects(from previous: ActiveStates, to next: ActiveStates) -> [TransitionEffect] {
        var effects: [TransitionEffect] = []
        if previous.current == .ok, let state = next.current.blocking {
            effects += [.cancelInFlight(state), .releaseHeldInput, .invalidateFrames]
        }
        if next.states.subtracting(previous.states).contains(where: \.dropsLease) {
            effects.append(.dropLease)
        }
        return effects
    }
}
