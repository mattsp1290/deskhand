import DeskhandCore
import Testing

@Suite struct ArmingTests {
    private typealias F = StateFixture

    struct Row: Sendable, CustomTestStringConvertible {
        let from: Arming
        let command: ArmingCommand?
        let at: ClockReading
        let to: Arming
        let testDescription: String

        init(_ description: String, _ from: Arming, _ command: ArmingCommand?, at: ClockReading, _ to: Arming) {
            self.from = from
            self.command = command
            self.at = at
            self.to = to
            testDescription = description
        }
    }

    private static let until = StateFixture.armedUntil
    private static let t0 = StateFixture.t0
    private static let atExpiry = StateFixture.at(3_600_000)
    private static let later = StateFixture.at(3_660_000)

    /// Contract 10.4 and Appendix A 26.
    static let rows: [Row] = [
        Row("disarmed stays disarmed", .disarmed, nil, at: t0, .disarmed),
        Row("arming from disarmed", .disarmed, .arm(for: F.armingPeriod), at: t0, .armed(until: until)),
        Row("arming for no time arms nothing", .disarmed, .arm(for: .zero), at: t0, .disarmed),
        Row("disarm while disarmed", .disarmed, .disarm, at: t0, .disarmed),
        Row("kill switch while disarmed", .disarmed, .killSwitch, at: t0, .paused),
        Row("armed just before expiry", .armed(until: until), nil, at: F.at(3_599_999), .armed(until: until)),
        Row("arming runs out at armed_until", .armed(until: until), nil, at: atExpiry, .disarmed),
        Row("arming runs out after armed_until", .armed(until: until), nil, at: later, .disarmed),
        Row("disarm while armed", .armed(until: until), .disarm, at: t0, .disarmed),
        Row("kill switch ends arming", .armed(until: until), .killSwitch, at: t0, .paused),
        Row(
            "arming again moves armed_until", .armed(until: until), .arm(for: .seconds(7200)), at: t0,
            .armed(until: F.at(7_200_000).monotonic)),
        Row(
            "arming again at expiry", .armed(until: until), .arm(for: F.armingPeriod), at: atExpiry,
            .armed(until: F.at(7_200_000).monotonic)),
        Row(
            "a negative period is ignored", .armed(until: until), .arm(for: .seconds(-1)), at: t0, .armed(until: until)),
        Row("paused outlasts time", .paused, nil, at: later, .paused),
        Row("disarm does not end paused", .paused, .disarm, at: t0, .paused),
        Row("kill switch again while paused", .paused, .killSwitch, at: t0, .paused),
        Row("arming ends paused", .paused, .arm(for: F.armingPeriod), at: t0, .armed(until: until)),
        Row("arming for no time does not end paused", .paused, .arm(for: .zero), at: t0, .paused),
    ]

    @Test(arguments: rows)
    func armingCommands(_ row: Row) {
        let previous = F.report(arming: row.from, signals: F.signals())
        #expect(previous.arming == row.from)
        let report = F.reduce(previous, F.signals(), row.command, at: row.at).report
        #expect(report.arming == row.to)
        #expect(report.armedUntil(at: row.at) == row.to.armedUntil(at: row.at))
        let expected: Set<BlockingState> =
            switch row.to {
            case .armed: []
            case .disarmed: [.disarmed]
            case .paused: [.paused, .disarmed]
            }
        #expect(report.activeStates(at: row.at).states == expected)
    }

    /// Contract 10.1: deskhand starts `disarmed`, and nothing from a previous run seeds it.
    @Test func firstReadingIsDisarmedWithNoEffects() {
        let (report, effects) = F.reduce(.startup, F.signals())
        #expect(report.state(at: F.t0) == .disarmed)
        #expect(report.activeStates(at: F.t0).states == [.disarmed])
        #expect(report.armedUntil(at: F.t0) == nil)
        #expect(effects.isEmpty)
    }

    /// Contract 10.4: the kill switch makes `paused` and `disarmed` hold together, with no
    /// `armed_until`, and does everything leaving `ok` does.
    @Test func killSwitchPausesAndDisarms() {
        let armed = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        #expect(armed.state(at: F.t0) == .ok)
        let (report, effects) = F.reduce(armed, F.signals(), .killSwitch)
        #expect(report.state(at: F.t0) == .paused)
        #expect(report.activeStates(at: F.t0).inPrecedenceOrder == [.paused, .disarmed])
        #expect(report.armedUntil(at: F.t0) == nil)
        #expect(effects == [.cancelInFlight(.paused), .releaseHeldInput, .invalidateFrames, .dropLease(.paused)])
    }

    /// Contract 10.4 and Appendix A 27: by default `gated` ends arming, so when the allowance returns
    /// the state is `disarmed` until a person arms again.
    @Test func gatedEndsArmingByDefault() {
        let armed = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        let gated = F.reduce(armed, F.signals(holding: [.gated]), configuration: .standard)
        #expect(gated.report.activeStates(at: F.t0).inPrecedenceOrder == [.gated, .disarmed])
        #expect(gated.report.armedUntil(at: F.t0) == nil)
        #expect(gated.effects == [.cancelInFlight(.gated), .releaseHeldInput, .invalidateFrames, .dropLease(.gated)])

        let back = F.reduce(gated.report, F.signals(), at: F.at(1), configuration: .standard)
        #expect(back.report.state(at: F.at(1)) == .disarmed)
        #expect(back.effects.isEmpty)

        let rearmed = F.reduce(
            back.report, F.signals(), .arm(for: F.armingPeriod), at: F.at(2), configuration: .standard)
        #expect(rearmed.report.state(at: F.at(2)) == .ok)
    }

    /// A person can still arm while `gated`; only `gated` beginning ends arming.
    @Test func armingDuringGatedStands() {
        let gatedSignals = F.signals(holding: [.gated])
        let disarmed = F.report(arming: .disarmed, signals: gatedSignals)
        let armed = F.reduce(disarmed, gatedSignals, .arm(for: F.armingPeriod), configuration: .standard)
        #expect(armed.report.activeStates(at: F.t0).states == [.gated])
        let still = F.reduce(armed.report, gatedSignals, at: F.at(1000), configuration: .standard)
        #expect(still.report.activeStates(at: F.at(1000)).states == [.gated])
        let back = F.reduce(still.report, F.signals(), at: F.at(2000), configuration: .standard)
        #expect(back.report.state(at: F.at(2000)) == .ok)
    }

    /// With `gated_ends_arming` false, `gated` and arming are independent: if the allowance returns
    /// before arming runs out, the state is `ok` again with nobody at the Mac.
    @Test func gatedLeavesArmingAloneWhenConfigured() {
        let armed = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        let gated = F.reduce(armed, F.signals(holding: [.gated]))
        #expect(gated.report.state(at: F.t0) == .gated)
        #expect(gated.report.armedUntil(at: F.t0) == F.t0.wallTime(at: F.armedUntil))
        #expect(gated.effects == [.cancelInFlight(.gated), .releaseHeldInput, .invalidateFrames, .dropLease(.gated)])

        let back = F.reduce(gated.report, F.signals(), at: F.at(1))
        #expect(back.report.state(at: F.at(1)) == .ok)
        #expect(back.effects.isEmpty)

        let ranOut = F.reduce(gated.report, F.signals(holding: [.gated]), at: F.at(3_600_000))
        #expect(ranOut.report.activeStates(at: F.at(3_600_000)).inPrecedenceOrder == [.gated, .disarmed])
        #expect(ranOut.effects == [.dropLease(.disarmed)])
    }

    /// Contract 10.4, "Only a person arms".
    @Test func onlyAPersonArms() {
        let disarmed = F.report(arming: .disarmed, signals: F.signals())
        let cases: [(OwnInputActivity, ArmingRefusal?)] = [
            (.idle, nil),
            (
                OwnInputActivity(commandFromPostedEvent: true, operationExecuting: false, lastPostedEvent: nil),
                .postedEvent
            ),
            (
                OwnInputActivity(commandFromPostedEvent: false, operationExecuting: true, lastPostedEvent: nil),
                .operationExecuting
            ),
            (
                OwnInputActivity(
                    commandFromPostedEvent: false, operationExecuting: false, lastPostedEvent: F.at(-2999).monotonic),
                .recentPostedEvent
            ),
            (
                OwnInputActivity(
                    commandFromPostedEvent: false, operationExecuting: false, lastPostedEvent: F.at(-3000).monotonic),
                nil
            ),
        ]
        for (activity, refusal) in cases {
            #expect(ArmingRefusal.of(.arm(for: F.armingPeriod), activity: activity, now: F.t0) == refusal)
            let report = F.reduce(disarmed, F.signals(ownInput: activity), .arm(for: F.armingPeriod)).report
            #expect(report.state(at: F.t0) == (refusal == nil ? .ok : .disarmed), "\(activity)")
        }
        let busy = OwnInputActivity(
            commandFromPostedEvent: true, operationExecuting: true, lastPostedEvent: F.t0.monotonic)
        #expect(ArmingRefusal.of(.disarm, activity: busy, now: F.t0) == nil)
        #expect(ArmingRefusal.of(.killSwitch, activity: busy, now: F.t0) == nil)
        let armed = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        #expect(F.reduce(armed, F.signals(ownInput: busy), .killSwitch).report.arming == .paused)
        #expect(F.reduce(armed, F.signals(ownInput: busy), .arm(for: .seconds(7200))).report.arming == armed.arming)
        let paused = F.report(arming: .paused, signals: F.signals())
        #expect(F.reduce(paused, F.signals(ownInput: busy), .arm(for: F.armingPeriod)).report.arming == .paused)
    }

    /// A report read after `armed_until` is not `ok`, whoever holds it, without a reduction.
    @Test func aHeldReportStopsBeingOKWhenArmingRunsOut() {
        let armed = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        #expect(armed.state(at: F.at(3_599_999)) == .ok)
        #expect(armed.state(at: F.at(3_600_000)) == .disarmed)
        #expect(armed.armedUntil(at: F.at(3_600_000)) == nil)
        #expect(armed.validUntil(at: F.t0) == F.armedUntil)
    }

    /// The allowance's expiry is compared with the clock on every read of a report, and ends arming
    /// as `gated` beginning does.
    @Test func aHeldReportTurnsGatedWhenTheAllowanceExpires() {
        let expiry = F.at(10_000)
        let signals = StateSignals(
            allowance: .valid(expiresAt: expiry.wall), readings: F.signals().readings, credentialsWarning: false,
            cleanupPending: false, logUnavailable: false, ownInput: .idle)
        let report = F.reduce(
            F.report(arming: .disarmed, signals: signals), signals, .arm(for: F.armingPeriod),
            configuration: .standard
        ).report
        #expect(report.state(at: F.at(9999)) == .ok)
        #expect(report.activeStates(at: expiry).inPrecedenceOrder == [.gated, .disarmed])
        #expect(report.validUntil(at: F.t0) == expiry.monotonic)

        let independent = F.reduce(F.report(arming: .disarmed, signals: signals), signals, .arm(for: F.armingPeriod))
            .report
        #expect(independent.activeStates(at: expiry).inPrecedenceOrder == [.gated])
    }

    /// The deadline of an effect is the earliest of the allowance, the lease and the arming.
    @Test func effectDeadlineIsTheEarliestEnd() {
        let signals = StateSignals(
            allowance: .valid(expiresAt: F.at(20_000).wall), readings: F.signals().readings,
            credentialsWarning: false, cleanupPending: false, logUnavailable: false, ownInput: .idle)
        let report = F.reduce(F.report(arming: .disarmed, signals: signals), signals, .arm(for: .seconds(10))).report
        var manager = LeaseManager()
        let arguments = LeaseArguments(holderID: HolderID("h")!, command: .acquire(ttlMs: 30_000))
        _ = manager.apply(arguments, principal: Principal(certificateSubject: "CN=c"), state: .ok, now: F.t0)
        guard case .held(let lease) = manager.lease else {
            Issue.record("no lease")
            return
        }
        #expect(report.effectDeadline(lease: lease, at: F.t0) == F.at(10_000).monotonic)
    }

    /// Arming is measured on the monotonic clock: setting the wall clock back does not lengthen it.
    @Test func aWallClockStepDoesNotLengthenArming() {
        let armed = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        let steppedBack = ClockReading(wall: F.at(-86_400_000).wall, monotonic: F.at(3_600_000).monotonic)
        #expect(armed.state(at: steppedBack) == .disarmed)
        let reduced = F.reduce(armed, F.signals(), at: steppedBack).report
        #expect(reduced.arming == .disarmed)
    }
}
