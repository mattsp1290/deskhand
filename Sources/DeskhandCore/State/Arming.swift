/// deskhand's own arming state (contract 10.4). It lives only in memory: every start is `disarmed`,
/// and neither arming nor `paused` survives a restart.
public enum Arming: Hashable, Sendable {
    /// Armed until `until` on the monotonic clock, so a wall-clock step never lengthens it.
    case armed(until: ContinuousClock.Instant)
    case disarmed
    /// The kill switch was used and nobody has armed deskhand since. Arming ended with it, so
    /// `paused` always comes with `disarmed`.
    case paused

    /// `status.armed_until` as seen from `now`, or `nil` when not armed at `now`.
    public func armedUntil(at now: ClockReading) -> Timestamp? {
        guard case .armed(let until) = self, now.monotonic < until else { return nil }
        return now.wallTime(at: until)
    }

    func settled(at now: ClockReading) -> Arming {
        if case .armed(let until) = self, now.monotonic >= until { return .disarmed }
        return self
    }

    var blockingStates: [BlockingState] {
        switch self {
        case .armed: []
        case .disarmed: [.disarmed]
        case .paused: [.paused, .disarmed]
        }
    }

    func applying(_ command: ArmingCommand?, refusal: ArmingRefusal?, now: ClockReading) -> Arming {
        let current = settled(at: now)
        switch (command, current) {
        case (nil, _): return current
        case (.killSwitch, _): return .paused
        case (.arm(let duration), _):
            guard refusal == nil, duration > .zero else { return current }
            return .armed(until: now.monotonic.advanced(by: duration))
        case (.disarm, .armed): return .disarmed
        case (.disarm, _): return current
        }
    }
}

/// What a person at the Mac does to arming, from the menu bar or the kill-switch hot key.
/// No call over the wire can issue one (contract 10.1).
public enum ArmingCommand: Hashable, Sendable {
    /// Arm for the chosen duration from now, also when already armed (extending). Ends `paused` and
    /// `disarmed` alike, and is the only way to end `paused`. A duration that is not positive arms
    /// nothing and changes nothing.
    case arm(for: Duration)
    /// End arming early. `paused` stays.
    case disarm
    /// `paused` begins and arming ends.
    case killSwitch

    /// Arming, extending arming and leaving `paused` must come from the person (contract 10.4).
    public var needsPerson: Bool {
        if case .arm = self { return true }
        return false
    }
}

/// Why an arming command was not accepted (contract 10.4, "Only a person arms"). Disarming and the
/// kill switch are never refused.
public enum ArmingRefusal: Hashable, Sendable {
    /// The command came from an input event that deskhand posted itself.
    case postedEvent
    /// An operation is executing.
    case operationExecuting
    /// deskhand posted an event less than `USER_ACTIVITY_LOOKBACK_MS` ago.
    case recentPostedEvent

    /// Why `command` cannot be accepted given what deskhand itself is doing, or `nil`.
    public static func of(_ command: ArmingCommand?, activity: OwnInputActivity, now: ClockReading) -> ArmingRefusal? {
        guard let command, command.needsPerson else { return nil }
        if activity.commandFromPostedEvent { return .postedEvent }
        if activity.operationExecuting { return .operationExecuting }
        if let last = activity.lastPostedEvent,
            last.duration(to: now.monotonic) < .milliseconds(ContractConstants.userActivityLookbackMs)
        {
            return .recentPostedEvent
        }
        return nil
    }
}
