/// Per-Mac settings that change how states combine.
public struct StateConfiguration: Hashable, Sendable {
    /// `gated_ends_arming` (contract 10.4): arming ends when `gated` begins.
    public var gatedEndsArming: Bool

    public init(gatedEndsArming: Bool) { self.gatedEndsArming = gatedEndsArming }

    /// The contract's defaults.
    public static let standard = StateConfiguration(gatedEndsArming: true)
}

/// The state deskhand reports, and the arming it carries into the next reduction.
///
/// A report goes stale without a reduction when arming runs out or the allowance expires, so it is
/// read through ``activeStates(at:)`` and ``state(at:)``, which apply both with the clock: a report
/// that was `ok` one millisecond before `armed_until` is not `ok` after it, whoever holds it. The
/// owner still reduces again by ``validUntil(at:)`` so that the transition's effects run.
/// `status.conditions` is ``conditions`` plus `user_active`, which `status` evaluates when it is
/// called (contract 11.5).
public struct StateReport: Hashable, Sendable {
    public let arming: Arming
    /// Never contains `user_active`.
    public let conditions: Set<Condition>
    /// The states as of the reduction that made this report.
    let reducedStates: ActiveStates
    let allowance: AllowanceVerdict
    let gatedEndsArming: Bool

    init(arming: Arming, signals: StateSignals, configuration: StateConfiguration, now: ClockReading) {
        var states = Set(arming.blockingStates)
        if !signals.allowance.isValid(at: now.wall) { states.insert(.gated) }
        for signal in PlatformSignal.allCases where signals[signal].holds { states.insert(signal.feeds) }
        var conditions: Set<Condition> = []
        if signals.credentialsWarning { conditions.insert(.credentialsWarning) }
        if signals.cleanupPending { conditions.insert(.cleanupPending) }
        if signals.logUnavailable { conditions.insert(.logUnavailable) }
        if signals[.loginWindow].holds { conditions.insert(.loginWindow) }
        self.arming = arming
        self.reducedStates = ActiveStates(states)
        self.conditions = conditions
        self.allowance = signals.allowance
        self.gatedEndsArming = configuration.gatedEndsArming
    }

    /// The states that hold at `now`: those of the reduction, plus `disarmed` once arming has run
    /// out and `gated` once the allowance has expired. `status.active_states`, and what every
    /// admission and per-event check reads.
    public func activeStates(at now: ClockReading) -> ActiveStates {
        var states = reducedStates.states
        // `gated` that begins after the reduction ends arming as the next reduction will.
        let gatedBegan = !states.contains(.gated) && !allowance.isValid(at: now.wall)
        if gatedBegan { states.insert(.gated) }
        if case .armed = arming, arming.settled(at: now) == .disarmed || (gatedBegan && gatedEndsArming) {
            states.insert(.disarmed)
        }
        return ActiveStates(states)
    }

    /// `status.state` at `now`.
    public func state(at now: ClockReading) -> DeskhandState { activeStates(at: now).current }

    /// `status.armed_until` at `now`.
    public func armedUntil(at now: ClockReading) -> Timestamp? {
        activeStates(at: now).states.contains(.disarmed) ? nil : arming.armedUntil(at: now)
    }

    /// The instant this report stops describing the Mac without a new reduction: when arming runs
    /// out or the allowance expires, whichever is first. The owner reduces again at this instant at
    /// the latest. `nil` when neither can happen.
    public func validUntil(at now: ClockReading) -> ContinuousClock.Instant? {
        var instants: [ContinuousClock.Instant] = []
        if case .armed(let until) = arming { instants.append(until) }
        if case .valid(let expiresAt) = allowance { instants.append(now.instant(atWallTime: expiresAt)) }
        return instants.min()
    }

    /// The deadline of an effect executing under `lease` (contract 13.1): the earliest of the
    /// allowance's expiry, the lease's and the arming's. Already past when any of them has ended.
    public func effectDeadline(lease: Lease, at now: ClockReading) -> ContinuousClock.Instant {
        min(lease.deadline, validUntil(at: now) ?? lease.deadline)
    }

    /// The report before anything has been read: `disarmed`, as every start is, and every state that
    /// a missing reading makes hold. Seed the first ``StateReducer/reduce(previous:signals:command:configuration:now:)``
    /// with it.
    public static let startup = StateReport(
        arming: .disarmed, signals: .unread, configuration: .standard,
        now: ClockReading(wall: Timestamp(millisecondsSinceEpoch: 0), monotonic: ContinuousClock.now))
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
    /// `gated`, `paused` or `disarmed` began (contract 10.4): pass it to
    /// ``LeaseManager/drop(because:now:)``. It is the highest of those that began.
    case dropLease(LeaseDroppingState)
}

/// One owner keeps the latest ``StateReport``, feeds it back as `previous` and serializes the
/// reductions, so that no transition and none of its effects is skipped.
public enum StateReducer {
    /// The report for `signals` at `now`, after `command` if a person issued one, and the effects of
    /// the change from `previous`. Pure: the same arguments always give the same result.
    ///
    /// An arming command that ``ArmingRefusal/of(_:activity:now:)`` refuses leaves arming as it was.
    /// When `gated` begins and the configuration says so, arming ends.
    public static func reduce(
        previous: StateReport, signals: StateSignals, command: ArmingCommand? = nil,
        configuration: StateConfiguration = .standard, now: ClockReading
    ) -> (report: StateReport, effects: [TransitionEffect]) {
        let refusal = ArmingRefusal.of(command, activity: signals.ownInput, now: now)
        var arming = previous.arming.applying(command, refusal: refusal, now: now)
        let gatedBegins = !signals.allowance.isValid(at: now.wall) && !previous.reducedStates.states.contains(.gated)
        if gatedBegins, configuration.gatedEndsArming, case .armed = arming { arming = .disarmed }
        let report = StateReport(arming: arming, signals: signals, configuration: configuration, now: now)
        return (report, effects(from: previous.reducedStates, to: report.reducedStates))
    }

    private static func effects(from previous: ActiveStates, to next: ActiveStates) -> [TransitionEffect] {
        var effects: [TransitionEffect] = []
        if previous.current == .ok, let state = next.current.blocking {
            effects += [.cancelInFlight(state), .releaseHeldInput, .invalidateFrames]
        }
        if let dropping = next.states.subtracting(previous.states).compactMap(\.leaseDropping).min() {
            effects.append(.dropLease(dropping))
        }
        return effects
    }
}
