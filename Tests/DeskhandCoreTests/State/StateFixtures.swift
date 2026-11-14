import DeskhandCore

/// Contract section 10, highest first, written out rather than taken from `allCases`.
let contractPrecedence: [BlockingState] = [
    .gated, .paused, .disarmed, .notConsole, .locked, .displayAsleep, .permissionMissing, .permissionStale,
    .secureInput,
]

/// Contract sections 10 and 11.4: the state each platform signal makes hold.
let stateFedBy: [PlatformSignal: BlockingState] = [
    .notConsole: .notConsole, .loginWindow: .notConsole, .locked: .locked, .displayAsleep: .displayAsleep,
    .permissionMissing: .permissionMissing, .permissionStale: .permissionStale, .secureInput: .secureInput,
]

let leaseDroppingStates: Set<BlockingState> = [.gated, .paused, .disarmed]

/// The highest-precedence state in `states`, or `ok`.
func expectedState(_ states: Set<BlockingState>) -> DeskhandState {
    contractPrecedence.first(where: states.contains)?.state ?? .ok
}

/// Every subset of the blocking states, `paused` without `disarmed` included.
let everyBlockingSubset: [Set<BlockingState>] = (0..<(1 << contractPrecedence.count)).map { mask in
    Set(contractPrecedence.indices.filter { mask & (1 << $0) != 0 }.map { contractPrecedence[$0] })
}

/// How arming gets from one value to another in a single reduction.
enum ArmingStep: Equatable {
    /// `command` is `nil` when arming does not change.
    case reachable(command: ArmingCommand?)
    /// `paused` ends only by arming, so `paused` to plain `disarmed` takes two steps.
    case unreachable
}

enum StateFixture {
    static let t0 = Timestamp(millisecondsSinceEpoch: 1_794_668_539_730)
    static let armedUntil = t0.adding(milliseconds: 3_600_000)

    /// Signals under which exactly the platform states in `states` hold and the allowance is valid
    /// unless `states` has `gated`. A `loginWindow` condition also makes `not_console` hold.
    static func signals(holding states: Set<BlockingState> = [], conditions: Set<Condition> = []) -> StateSignals {
        var readings: [PlatformSignal: SignalReading] = [:]
        for signal in PlatformSignal.allCases {
            let holds = signal != .loginWindow && states.contains(stateFedBy[signal]!)
            readings[signal] = holds ? .present : .absent
        }
        if conditions.contains(.loginWindow) { readings[.loginWindow] = .present }
        return StateSignals(
            allowanceValid: !states.contains(.gated), readings: readings,
            credentialsWarning: conditions.contains(.credentialsWarning),
            cleanupPending: conditions.contains(.cleanupPending), logUnavailable: conditions.contains(.logUnavailable))
    }

    /// The arming under which `paused` and `disarmed` hold as they do in `states`, or `nil` for
    /// `paused` without `disarmed`, which no sequence of commands reaches.
    static func arming(for states: Set<BlockingState>) -> Arming? {
        switch (states.contains(.paused), states.contains(.disarmed)) {
        case (true, true): .paused
        case (false, true): .disarmed
        case (false, false): .armed(until: armedUntil)
        case (true, false): nil
        }
    }

    static func step(from: Arming, to: Arming) -> ArmingStep {
        switch (from, to) {
        case (.paused, .disarmed): .unreachable
        case _ where from == to: .reachable(command: nil)
        case (_, .armed(let until)): .reachable(command: .arm(until: until))
        case (_, .disarmed): .reachable(command: .disarm)
        case (_, .paused): .reachable(command: .killSwitch)
        }
    }

    /// A report with `arming`, reached from `startup` through the public commands at `t0`.
    static func report(arming: Arming, signals: StateSignals) -> StateReport {
        let command: ArmingCommand? =
            switch arming {
            case .armed(let until): .arm(until: until)
            case .disarmed: nil
            case .paused: .killSwitch
            }
        return StateReducer.reduce(previous: .startup, signals: signals, command: command, now: t0).report
    }

    /// A report in which exactly `states` hold, or `nil` when that set is unreachable.
    static func report(holding states: Set<BlockingState>, conditions: Set<Condition> = []) -> StateReport? {
        arming(for: states).map { report(arming: $0, signals: signals(holding: states, conditions: conditions)) }
    }
}
