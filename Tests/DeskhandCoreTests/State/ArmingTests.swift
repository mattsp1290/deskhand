import DeskhandCore
import Testing

@Suite struct ArmingTests {
    private typealias F = StateFixture

    struct Row: Sendable, CustomTestStringConvertible {
        let from: Arming
        let command: ArmingCommand?
        let at: Timestamp
        let to: Arming
        let testDescription: String

        init(_ description: String, _ from: Arming, _ command: ArmingCommand?, at: Timestamp, _ to: Arming) {
            self.from = from
            self.command = command
            self.at = at
            self.to = to
            testDescription = description
        }
    }

    private static let until = StateFixture.armedUntil
    private static let t0 = StateFixture.t0
    private static let later = until.adding(milliseconds: 60_000)

    /// Contract 10.4 and Appendix A 26.
    static let rows: [Row] = [
        Row("disarmed stays disarmed", .disarmed, nil, at: t0, .disarmed),
        Row("arming from disarmed", .disarmed, .arm(until: until), at: t0, .armed(until: until)),
        Row("arming until now arms nothing", .disarmed, .arm(until: t0), at: t0, .disarmed),
        Row("disarm while disarmed", .disarmed, .disarm, at: t0, .disarmed),
        Row("kill switch while disarmed", .disarmed, .killSwitch, at: t0, .paused),
        Row(
            "armed just before expiry", .armed(until: until), nil, at: until.adding(milliseconds: -1),
            .armed(until: until)),
        Row("arming runs out at armed_until", .armed(until: until), nil, at: until, .disarmed),
        Row("arming runs out after armed_until", .armed(until: until), nil, at: later, .disarmed),
        Row("disarm while armed", .armed(until: until), .disarm, at: t0, .disarmed),
        Row("kill switch ends arming", .armed(until: until), .killSwitch, at: t0, .paused),
        Row("arming again moves armed_until", .armed(until: until), .arm(until: later), at: t0, .armed(until: later)),
        Row("arming again at expiry", .armed(until: until), .arm(until: later), at: until, .armed(until: later)),
        Row("arming into the past is ignored", .armed(until: until), .arm(until: t0), at: t0, .armed(until: until)),
        Row("paused outlasts time", .paused, nil, at: later, .paused),
        Row("disarm does not end paused", .paused, .disarm, at: t0, .paused),
        Row("kill switch again while paused", .paused, .killSwitch, at: t0, .paused),
        Row("arming ends paused", .paused, .arm(until: until), at: t0, .armed(until: until)),
        Row("arming until now does not end paused", .paused, .arm(until: t0), at: t0, .paused),
    ]

    @Test(arguments: rows)
    func armingCommands(_ row: Row) {
        let previous = F.report(arming: row.from, signals: F.signals())
        #expect(previous.arming == row.from)
        let report = StateReducer.reduce(previous: previous, signals: F.signals(), command: row.command, now: row.at)
            .report
        #expect(report.arming == row.to)
        #expect(report.armedUntil == row.to.armedUntil)
        let expected: Set<BlockingState> =
            switch row.to {
            case .armed: []
            case .disarmed: [.disarmed]
            case .paused: [.paused, .disarmed]
            }
        #expect(report.activeStates.states == expected)
    }

    /// Contract 10.1: deskhand starts `disarmed`, and nothing from a previous run seeds it.
    @Test func firstReadingIsDisarmedWithNoEffects() {
        let (report, effects) = StateReducer.reduce(previous: .startup, signals: F.signals(), now: F.t0)
        #expect(report.state == .disarmed)
        #expect(report.activeStates.states == [.disarmed])
        #expect(report.armedUntil == nil)
        #expect(effects.isEmpty)
    }

    /// Contract 10.4: the kill switch makes `paused` and `disarmed` hold together, with no
    /// `armed_until`, and does everything leaving `ok` does.
    @Test func killSwitchPausesAndDisarms() {
        let armed = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        #expect(armed.state == .ok)
        let (report, effects) = StateReducer.reduce(
            previous: armed, signals: F.signals(), command: .killSwitch, now: F.t0)
        #expect(report.state == .paused)
        #expect(report.activeStates.inPrecedenceOrder == [.paused, .disarmed])
        #expect(report.armedUntil == nil)
        #expect(effects == [.cancelInFlight(.paused), .releaseHeldInput, .invalidateFrames, .dropLease])
    }

    /// Contract 10.4 and Appendix A 27: `gated` does not end arming. If the allowance returns before
    /// arming runs out, the state is `ok` again with nobody at the Mac, and nothing is restored.
    @Test func gatedDoesNotEndArming() {
        let armed = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        let gated = StateReducer.reduce(previous: armed, signals: F.signals(holding: [.gated]), now: F.t0)
        #expect(gated.report.state == .gated)
        #expect(gated.report.armedUntil == F.armedUntil)
        #expect(gated.effects == [.cancelInFlight(.gated), .releaseHeldInput, .invalidateFrames, .dropLease])

        let back = StateReducer.reduce(previous: gated.report, signals: F.signals(), now: F.t0.adding(milliseconds: 1))
        #expect(back.report.state == .ok)
        #expect(back.report.armedUntil == F.armedUntil)
        #expect(back.effects.isEmpty)
    }

    /// Arming is independent of the allowance in the other direction too: a person can arm while
    /// `gated`, and arming can run out while `gated`.
    @Test func armingRunsIndependentlyOfTheGate() {
        let gatedSignals = F.signals(holding: [.gated])
        let disarmed = F.report(arming: .disarmed, signals: gatedSignals)
        let armed = StateReducer.reduce(
            previous: disarmed, signals: gatedSignals, command: .arm(until: F.armedUntil), now: F.t0)
        #expect(armed.report.activeStates.states == [.gated])
        #expect(armed.effects.isEmpty)

        let ranOut = StateReducer.reduce(previous: armed.report, signals: gatedSignals, now: F.armedUntil)
        #expect(ranOut.report.activeStates.inPrecedenceOrder == [.gated, .disarmed])
        #expect(ranOut.effects == [.dropLease])
    }
}
