import DeskhandCore

let contractPrecedence: [BlockingState] = [
    .gated, .paused, .disarmed, .notConsole, .locked, .displayAsleep, .permissionMissing, .permissionStale,
    .secureInput,
]

let stateFedBy: [PlatformSignal: BlockingState] = [
    .notConsole: .notConsole, .loginWindow: .notConsole, .locked: .locked, .displayAsleep: .displayAsleep,
    .permissionMissing: .permissionMissing, .permissionStale: .permissionStale, .secureInput: .secureInput,
]

let leaseDroppingStates: Set<BlockingState> = [.gated, .paused, .disarmed]

func expectedState(_ states: Set<BlockingState>) -> DeskhandState {
    contractPrecedence.first(where: states.contains)?.state ?? .ok
}

let everyBlockingSubset: [Set<BlockingState>] = (0..<(1 << contractPrecedence.count)).map { mask in
    Set(contractPrecedence.indices.filter { mask & (1 << $0) != 0 }.map { contractPrecedence[$0] })
}

enum ArmingStep: Equatable {
    case reachable(command: ArmingCommand?)
    case unreachable
}

enum StateFixture {
    static let t0 = ClockReading(wall: Timestamp(millisecondsSinceEpoch: 1_794_668_539_730), monotonic: .now)
    static let armingPeriod: Duration = .seconds(3600)
    static let armedUntil = t0.monotonic.advanced(by: armingPeriod)
    static let allowance = AllowanceVerdict.valid(expiresAt: t0.wall.adding(milliseconds: 365 * 86_400_000))
    static let gateIndependent = StateConfiguration(gatedEndsArming: false)

    static func at(_ offsetMs: Int64) -> ClockReading { t0.advanced(byMilliseconds: offsetMs) }

    static func signals(
        holding states: Set<BlockingState> = [], conditions: Set<Condition> = [], ownInput: OwnInputActivity = .idle
    ) -> StateSignals {
        var readings: [PlatformSignal: SignalReading] = [:]
        for signal in PlatformSignal.allCases {
            let holds = signal != .loginWindow && states.contains(stateFedBy[signal]!)
            readings[signal] = holds ? .present : .absent
        }
        if conditions.contains(.loginWindow) { readings[.loginWindow] = .present }
        return StateSignals(
            allowance: states.contains(.gated) ? .missing : allowance, readings: readings,
            credentialsWarning: conditions.contains(.credentialsWarning),
            cleanupPending: conditions.contains(.cleanupPending), logUnavailable: conditions.contains(.logUnavailable),
            ownInput: ownInput)
    }

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
        case (_, .armed(let until)): .reachable(command: .arm(for: t0.monotonic.duration(to: until)))
        case (_, .disarmed): .reachable(command: .disarm)
        case (_, .paused): .reachable(command: .killSwitch)
        }
    }

    static func reduce(
        _ previous: StateReport, _ signals: StateSignals, _ command: ArmingCommand? = nil, at now: ClockReading = t0,
        configuration: StateConfiguration = gateIndependent
    ) -> (report: StateReport, effects: [TransitionEffect]) {
        StateReducer.reduce(
            previous: previous, signals: signals, command: command, configuration: configuration, now: now)
    }

    static func report(arming: Arming, signals: StateSignals) -> StateReport {
        let command: ArmingCommand? =
            switch arming {
            case .armed(let until): .arm(for: t0.monotonic.duration(to: until))
            case .disarmed: nil
            case .paused: .killSwitch
            }
        return reduce(.startup, signals, command).report
    }

    static func report(holding states: Set<BlockingState>, conditions: Set<Condition> = []) -> StateReport? {
        arming(for: states).map { report(arming: $0, signals: signals(holding: states, conditions: conditions)) }
    }
}
