import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct StatePrecedenceTests {
    private typealias F = StateFixture

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
                        allowance: allowanceValid ? F.allowance : .missing, readings: values,
                        credentialsWarning: false, cleanupPending: false, logUnavailable: false, ownInput: .idle)
                    let report = F.reduce(previous, input).report

                    var expected: Set<BlockingState> = allowanceValid ? [] : [.gated]
                    if arming == .paused { expected.insert(.paused) }
                    if arming != .armed(until: F.armedUntil) { expected.insert(.disarmed) }
                    for (signal, value) in values where value != .absent { expected.insert(stateFedBy[signal]!) }
                    let expectedConditions: Set<Condition> = values[.loginWindow] == .absent ? [] : [.loginWindow]

                    let matches =
                        report.activeStates(at: F.t0).states == expected
                        && report.state(at: F.t0) == expectedState(expected)
                        && report.activeStates(at: F.t0).inPrecedenceOrder
                            == contractPrecedence.filter(expected.contains)
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

    @Test(arguments: PlatformSignal.allCases)
    func missingReadingFailsClosed(_ signal: PlatformSignal) {
        var input = F.signals()
        input.readings[signal] = nil
        #expect(input[signal] == .uncertain)
        let previous = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        let report = F.reduce(previous, input).report
        #expect(report.activeStates(at: F.t0).states == [stateFedBy[signal]!])
    }

    @Test func loginWindowOverridesConsoleOwnership() {
        var input = F.signals()
        input.readings[.notConsole] = .absent
        input.readings[.loginWindow] = .present
        let previous = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        let report = F.reduce(previous, input).report
        #expect(report.state(at: F.t0) == .notConsole)
        #expect(report.activeStates(at: F.t0).inPrecedenceOrder == [.notConsole])
        #expect(report.conditions == [.loginWindow])
    }

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
                let report = F.reduce(previous, input).report

                var expected: Set<Condition> = []
                if input.credentialsWarning { expected.insert(.credentialsWarning) }
                if input.cleanupPending { expected.insert(.cleanupPending) }
                if input.logUnavailable { expected.insert(.logUnavailable) }
                if loginWindow != .absent { expected.insert(.loginWindow) }
                #expect(report.conditions == expected)
                #expect(!report.conditions.contains(.userActive))
                #expect(report.state(at: F.t0) == (loginWindow == .absent ? .ok : .notConsole))
                checked += 1
            }
        }
        #expect(checked == 24)
    }

    @Test func startupHoldsEverythingUnreadAndIsDisarmed() {
        let startup = StateReport.startup
        #expect(startup.arming == .disarmed)
        #expect(startup.armedUntil(at: F.t0) == nil)
        #expect(startup.state(at: F.t0) == .gated)
        #expect(startup.activeStates(at: F.t0).inPrecedenceOrder == contractPrecedence.filter { $0 != .paused })
        #expect(startup.conditions == [.loginWindow])
    }
}
