import DeskhandCore
import Testing

@Suite struct StatePrecedenceTests {
    private typealias F = StateFixture

    /// Every allowance value, every arming and every reading of every platform signal: the active
    /// states are exactly those whose input holds, and the state is the highest of them.
    @Test func everyCombinationReportsTheHighestActiveState() {
        let signals = PlatformSignal.allCases
        let readings = SignalReading.allCases
        let readingCombinations = (0..<signals.count).reduce(1) { product, _ in product * readings.count }
        var checked = 0
        var mismatches = 0
        var samples: [String] = []

        for allowanceValid in [true, false] {
            for arming in [Arming.armed(until: F.armedUntil), .disarmed, .paused] {
                let previous = F.report(arming: arming, signals: F.signals())
                for combination in 0..<readingCombinations {
                    var values: [PlatformSignal: SignalReading] = [:]
                    var digits = combination
                    for signal in signals {
                        values[signal] = readings[digits % readings.count]
                        digits /= readings.count
                    }
                    let input = StateSignals(
                        allowanceValid: allowanceValid, readings: values, credentialsWarning: false,
                        cleanupPending: false, logUnavailable: false)
                    let report = StateReducer.reduce(previous: previous, signals: input, now: F.t0).report

                    var expected: Set<BlockingState> = allowanceValid ? [] : [.gated]
                    if arming == .paused { expected.insert(.paused) }
                    if arming != .armed(until: F.armedUntil) { expected.insert(.disarmed) }
                    for (signal, value) in values where value != .absent { expected.insert(stateFedBy[signal]!) }
                    let expectedConditions: Set<Condition> = values[.loginWindow] == .absent ? [] : [.loginWindow]

                    let matches =
                        report.activeStates.states == expected && report.state == expectedState(expected)
                        && report.activeStates.inPrecedenceOrder == contractPrecedence.filter(expected.contains)
                        && report.conditions == expectedConditions && report.arming == arming
                    if !matches {
                        mismatches += 1
                        if samples.count < 3 { samples.append("\(allowanceValid) \(arming) \(values) -> \(report)") }
                    }
                    checked += 1
                }
            }
        }

        #expect(checked == 2 * 3 * 2187)
        #expect(mismatches == 0, "first mismatches: \(samples)")
    }

    /// Contract 10.1: a signal that was not read at all counts as uncertain, so its state holds.
    @Test(arguments: PlatformSignal.allCases)
    func missingReadingFailsClosed(_ signal: PlatformSignal) {
        var input = F.signals()
        input.readings[signal] = nil
        #expect(input[signal] == .uncertain)
        let previous = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        let report = StateReducer.reduce(previous: previous, signals: input, now: F.t0).report
        #expect(report.activeStates.states == [stateFedBy[signal]!])
    }

    /// Contract 11.4: the login window is `not_console` even when the console-ownership signal
    /// says the session owns the console.
    @Test func loginWindowOverridesConsoleOwnership() {
        var input = F.signals()
        input.readings[.notConsole] = .absent
        input.readings[.loginWindow] = .present
        let previous = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        let report = StateReducer.reduce(previous: previous, signals: input, now: F.t0).report
        #expect(report.state == .notConsole)
        #expect(report.activeStates.inPrecedenceOrder == [.notConsole])
        #expect(report.conditions == [.loginWindow])
    }

    /// Every non-state condition the reducer reports, alone and together. None of them changes the
    /// state; only the login window, through its signal, makes `not_console` hold.
    @Test func conditionsAreReportedBesideTheState() {
        var checked = 0
        for mask in 0..<8 {
            for loginWindow in SignalReading.allCases {
                var input = F.signals()
                input.credentialsWarning = mask & 1 != 0
                input.cleanupPending = mask & 2 != 0
                input.logUnavailable = mask & 4 != 0
                input.readings[.loginWindow] = loginWindow
                let previous = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
                let report = StateReducer.reduce(previous: previous, signals: input, now: F.t0).report

                var expected: Set<Condition> = []
                if input.credentialsWarning { expected.insert(.credentialsWarning) }
                if input.cleanupPending { expected.insert(.cleanupPending) }
                if input.logUnavailable { expected.insert(.logUnavailable) }
                if loginWindow != .absent { expected.insert(.loginWindow) }
                #expect(report.conditions == expected)
                #expect(!report.conditions.contains(.userActive))
                #expect(report.state == (loginWindow == .absent ? .ok : .notConsole))
                checked += 1
            }
        }
        #expect(checked == 24)
    }

    /// Before the first reading deskhand is `disarmed`, and fails closed on everything it has not read.
    @Test func startupHoldsEverythingUnreadAndIsDisarmed() {
        let startup = StateReport.startup
        #expect(startup.arming == .disarmed)
        #expect(startup.armedUntil == nil)
        #expect(startup.state == .gated)
        #expect(startup.activeStates.inPrecedenceOrder == contractPrecedence.filter { $0 != .paused })
        #expect(startup.conditions == [.loginWindow])
    }
}
