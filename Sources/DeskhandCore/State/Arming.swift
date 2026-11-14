/// deskhand's own arming state (contract 10.4). It lives only in memory: every start is `disarmed`,
/// and neither arming nor `paused` survives a restart.
public enum Arming: Hashable, Sendable {
    case armed(until: Timestamp)
    case disarmed
    /// The kill switch was used and nobody has armed deskhand since. Arming ended with it, so
    /// `paused` always comes with `disarmed`.
    case paused

    /// `status.armed_until`.
    public var armedUntil: Timestamp? {
        if case .armed(let until) = self { until } else { nil }
    }

    var blockingStates: [BlockingState] {
        switch self {
        case .armed: []
        case .disarmed: [.disarmed]
        case .paused: [.paused, .disarmed]
        }
    }

    func applying(_ command: ArmingCommand?, now: Timestamp) -> Arming {
        let next: Arming
        switch (command, self) {
        case (nil, _): next = self
        case (.killSwitch, _): next = .paused
        case (.arm(let until), _): next = until > now ? .armed(until: until) : self
        case (.disarm, .armed): next = .disarmed
        case (.disarm, _): next = self
        }
        if case .armed(let until) = next, now >= until { return .disarmed }
        return next
    }
}

/// What a person at the Mac does to arming, from the menu bar or the kill-switch hot key.
/// No call over the wire can issue one (contract 10.1).
public enum ArmingCommand: Hashable, Sendable {
    /// Arm until the given time. Ends `paused` and `disarmed` alike, and is the only way to end
    /// `paused`. A time that is not after `now` arms nothing and changes nothing.
    case arm(until: Timestamp)
    /// End arming early. `paused` stays.
    case disarm
    /// `paused` begins and arming ends.
    case killSwitch
}
