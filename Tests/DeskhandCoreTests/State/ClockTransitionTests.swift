import DeskhandCore
import Testing

/// Transitions the clock makes on its own, arming running out and the allowance expiring, are
/// reduced even when the next reduction comes after the input that would hide them (contract 10.1,
/// 10.4, 13.1, 14.5; review finding 1 of both re-reviews).
@Suite struct ClockTransitionTests {
    private typealias F = StateFixture

    private static func leavingOK(_ state: BlockingState) -> [TransitionEffect] {
        [.cancelInFlight(state), .releaseHeldInput, .invalidateFrames, .dropLease(state.leaseDropping!)]
    }

    /// Signals with every platform state absent and the allowance valid until `offsetMs`.
    private static func signals(allowanceUntil offsetMs: Int64) -> StateSignals {
        var signals = F.signals()
        signals.allowance = .valid(expiresAt: F.at(offsetMs).wall)
        return signals
    }

    /// Armed for an hour under an allowance valid for 10 s.
    private static func armedUnderShortAllowance(_ configuration: StateConfiguration) -> StateReport {
        let signals = signals(allowanceUntil: 10_000)
        return F.reduce(.startup, signals, .arm(for: F.armingPeriod), configuration: configuration).report
    }

    /// Re-review probe: the allowance expires, readers see `gated` and `disarmed`, and a renewal is
    /// the next reading. The lapse still ends arming and runs its effects.
    @Test func aLapseRenewedBeforeTheNextReductionStillEndsArming() {
        let armed = Self.armedUnderShortAllowance(.standard)
        let seen = F.at(10_500)
        #expect(armed.activeStates(at: seen).inPrecedenceOrder == [.gated, .disarmed])
        #expect(armed.armedUntil(at: seen) == nil)

        let renewed = F.reduce(armed, Self.signals(allowanceUntil: 120_000), at: seen, configuration: .standard)
        #expect(renewed.effects == Self.leavingOK(.gated))
        #expect(renewed.report.arming == .disarmed)
        #expect(renewed.report.activeStates(at: seen).inPrecedenceOrder == [.disarmed])
        #expect(renewed.report.armedUntil(at: seen) == nil)
    }

    /// With `gated_ends_arming` false the lapse leaves arming alone, and still drops the lease and
    /// invalidates the frames.
    @Test func aLapseRenewedBeforeTheNextReductionRunsItsEffectsWhenArmingIsIndependent() {
        let configuration = StateConfiguration(gatedEndsArming: false)
        let armed = Self.armedUnderShortAllowance(configuration)
        let seen = F.at(10_500)
        #expect(armed.activeStates(at: seen).inPrecedenceOrder == [.gated])

        let renewed = F.reduce(armed, Self.signals(allowanceUntil: 120_000), at: seen, configuration: configuration)
        #expect(renewed.effects == Self.leavingOK(.gated))
        #expect(renewed.report.state(at: seen) == .ok)
        #expect(renewed.report.arming == .armed(until: F.armedUntil))
    }

    /// Re-review probe: arming runs out and the person arms again before the next reduction. The
    /// lease is dropped and the frames invalidated all the same.
    @Test func armingThatRanOutAndIsArmedAgainStillRunsItsEffects() {
        let armed = F.reduce(.startup, F.signals(), .arm(for: .seconds(10))).report
        let seen = F.at(10_001)
        #expect(armed.activeStates(at: seen).inPrecedenceOrder == [.disarmed])

        let rearmed = F.reduce(armed, F.signals(), .arm(for: F.armingPeriod), at: seen)
        #expect(rearmed.effects == Self.leavingOK(.disarmed))
        #expect(rearmed.report.state(at: seen) == .ok)
    }

    /// The existing row "arming again at expiry", with its effects.
    @Test func armingAgainExactlyAtExpiryRunsTheEffectsOfTheExpiry() {
        let armed = F.report(arming: .armed(until: F.armedUntil), signals: F.signals())
        let atExpiry = F.at(3_600_000)
        let rearmed = F.reduce(armed, F.signals(), .arm(for: F.armingPeriod), at: atExpiry)
        #expect(rearmed.effects == Self.leavingOK(.disarmed))
        #expect(rearmed.report.arming == .armed(until: F.at(7_200_000).monotonic))
    }

    /// Two lapses between reductions are reduced in the order they happened, each with its own
    /// effects.
    @Test func twoLapsesAreReducedInTheOrderTheyHappened() {
        let standard = StateConfiguration.standard
        let armingFirst = F.reduce(.startup, Self.signals(allowanceUntil: 8000), .arm(for: .seconds(5)))
            .report
        let late = F.at(9000)
        let first = F.reduce(armingFirst, Self.signals(allowanceUntil: 60_000), .arm(for: .seconds(60)), at: late)
        #expect(first.effects == Self.leavingOK(.disarmed) + [.dropLease(.gated)])
        #expect(first.report.state(at: late) == .ok)

        let allowanceFirst = F.reduce(
            .startup, Self.signals(allowanceUntil: 5000), .arm(for: .seconds(8)), configuration: standard
        ).report
        let second = F.reduce(allowanceFirst, Self.signals(allowanceUntil: 60_000), at: late, configuration: standard)
        #expect(second.effects == Self.leavingOK(.gated))
        #expect(second.report.activeStates(at: late).inPrecedenceOrder == [.disarmed])

        let independent = StateConfiguration(gatedEndsArming: false)
        let bothLapse = F.reduce(
            .startup, Self.signals(allowanceUntil: 5000), .arm(for: .seconds(8)), configuration: independent
        ).report
        let third = F.reduce(bothLapse, Self.signals(allowanceUntil: 60_000), at: late, configuration: independent)
        #expect(third.effects == Self.leavingOK(.gated) + [.dropLease(.disarmed)])
        #expect(third.report.activeStates(at: late).inPrecedenceOrder == [.disarmed])
    }

    /// Arming and the allowance ending at one instant are one transition, named by the higher state.
    @Test func lapsesAtOneInstantAreOneTransition() {
        let report = F.reduce(.startup, Self.signals(allowanceUntil: 5000), .arm(for: .seconds(5))).report
        #expect(report.validUntil(at: F.t0) == F.at(5000).monotonic)
        let later = F.reduce(report, Self.signals(allowanceUntil: 60_000), at: F.at(7000))
        #expect(later.effects == Self.leavingOK(.gated))
    }

    /// An allowance that expires within the same millisecond as arming, but after it, is still
    /// valid when arming runs out.
    @Test func anAllowanceExpiringJustAfterArmingIsStillValidWhenArmingEnds() {
        let report = F.reduce(.startup, Self.signals(allowanceUntil: 5000), .arm(for: .microseconds(4_999_600)))
            .report
        let later = F.reduce(report, Self.signals(allowanceUntil: 60_000), at: F.at(7000))
        #expect(later.effects == Self.leavingOK(.disarmed) + [.dropLease(.gated)])
    }

    /// Contract 13.1: the deadline of an executing effect is the earliest of the allowance, the
    /// lease and the arming, and a renewal moves it.
    @Test func aRenewalMovesTheEffectDeadline() throws {
        let principal = Principal(certificateSubject: "CN=c")
        let holder = HolderID("h")!
        let report = F.reduce(.startup, Self.signals(allowanceUntil: 60_000), .arm(for: F.armingPeriod)).report
        var leases = LeaseManager()
        _ = leases.apply(
            LeaseArguments(holderID: holder, command: .acquire(ttlMs: 10_000)), principal: principal, state: .ok,
            now: F.t0)
        let admitted = try leases.check(principal: principal, holderID: holder, now: F.t0)
        #expect(report.effectDeadline(of: admitted, leases: leases, at: F.t0) == F.at(10_000).monotonic)

        _ = leases.apply(
            LeaseArguments(holderID: holder, command: .renew(ttlMs: 30_000)), principal: principal, state: .ok,
            now: F.at(5000))
        #expect(report.effectDeadline(of: admitted, leases: leases, at: F.at(5000)) == F.at(35_000).monotonic)

        _ = leases.apply(
            LeaseArguments(holderID: holder, command: .renew(ttlMs: 120_000)), principal: principal, state: .ok,
            now: F.at(6000))
        #expect(report.effectDeadline(of: admitted, leases: leases, at: F.at(6000)) == F.at(60_000).monotonic)

        _ = leases.apply(
            LeaseArguments(holderID: holder, command: .release), principal: principal, state: .ok, now: F.at(7000))
        #expect(report.effectDeadline(of: admitted, leases: leases, at: F.at(7000)) == F.at(7000).monotonic)
    }

    /// The deadline is already past while arming or the allowance has ended.
    @Test func theEffectDeadlineIsPastWhileArmingOrTheAllowanceHasEnded() throws {
        let principal = Principal(certificateSubject: "CN=c")
        let holder = HolderID("h")!
        var leases = LeaseManager()
        _ = leases.apply(
            LeaseArguments(holderID: holder, command: .acquire(ttlMs: 30_000)), principal: principal, state: .ok,
            now: F.t0)
        let admitted = try leases.check(principal: principal, holderID: holder, now: F.t0)
        let disarmed = F.reduce(.startup, F.signals()).report
        #expect(disarmed.effectDeadline(of: admitted, leases: leases, at: F.at(100)) == F.at(100).monotonic)
        let gated = F.reduce(.startup, F.signals(holding: [.gated]), .arm(for: F.armingPeriod)).report
        #expect(gated.effectDeadline(of: admitted, leases: leases, at: F.at(100)) == F.at(100).monotonic)
    }

    /// For random histories of signals, commands and times, one reduction per input emits exactly
    /// the effects, and reaches exactly the report, of a reducer that also reduces at every instant
    /// at which arming runs out or the allowance expires. Readers of a held report see the states
    /// that reducer has reached.
    @Test func oneReductionPerInputEqualsAReducerSteppedAtEveryExpiry() {
        var checkedInputs = 0
        var clockSteps = 0
        var failures: [String] = []
        for seed in 0..<600 {
            // Seeded, so a failing history can be replayed from its seed.
            var random = SeededGenerator(state: UInt64(seed))
            let configuration = StateConfiguration(gatedEndsArming: Bool.random(using: &random))
            var actual = StateReport.startup
            var reference = StateReport.startup
            // What `startup` stands for: no allowance read.
            var lastSignals = F.signals(holding: [.gated])
            var lastMs: Int64 = 0
            var history: [String] = []

            for index in 0..<10 {
                let atMs = index == 0 ? 0 : lastMs + Self.randomStep(&random)
                let input = Self.randomInput(at: atMs, using: &random)
                history.append("\(atMs) ms: \(input.command.map { "\($0)" } ?? "-") \(input.signals.allowance)")

                // The reference reduces at every expiry; a reader of the held report checks halfway
                // and at the input.
                var expected: [TransitionEffect] = []
                var steppedMs = lastMs
                for checkpoint in [lastMs + (atMs - lastMs) / 2, atMs] {
                    let expiries = Self.expiryOffsets(
                        of: reference, signals: lastSignals, after: steppedMs, through: checkpoint)
                    for expiry in expiries {
                        let step = StateReducer.reduce(
                            previous: reference, signals: lastSignals, configuration: configuration,
                            now: F.at(expiry))
                        reference = step.report
                        expected += step.effects
                        clockSteps += 1
                    }
                    steppedMs = checkpoint
                    let seen = F.at(checkpoint)
                    if actual.activeStates(at: seen) != reference.activeStates(at: seen)
                        || actual.armedUntil(at: seen) != reference.armedUntil(at: seen)
                    {
                        failures.append("seed \(seed): readers at \(checkpoint) ms disagree; \(history)")
                    }
                }

                let once = StateReducer.reduce(
                    previous: actual, signals: input.signals, command: input.command, configuration: configuration,
                    now: F.at(atMs))
                let stepped = StateReducer.reduce(
                    previous: reference, signals: input.signals, command: input.command, configuration: configuration,
                    now: F.at(atMs))
                expected += stepped.effects
                if once.effects != expected || once.report != stepped.report {
                    failures.append("seed \(seed): \(once.effects) != \(expected); \(history)")
                }
                actual = once.report
                reference = stepped.report
                lastSignals = input.signals
                lastMs = atMs
                checkedInputs += 1
            }
        }
        #expect(checkedInputs == 6000)
        #expect(clockSteps > 1000, "the histories must exercise expiries between inputs")
        #expect(failures.isEmpty, "first failures: \(failures.prefix(3))")
    }

    private static func randomStep(_ random: inout SeededGenerator) -> Int64 {
        switch Int.random(in: 0..<10, using: &random) {
        case 0: 0
        case 1...5: Int64.random(in: 1...3000, using: &random)
        default: Int64.random(in: 3000...20_000, using: &random)
        }
    }

    private static func randomInput(at atMs: Int64, using random: inout SeededGenerator)
        -> (signals: StateSignals, command: ArmingCommand?)
    {
        var signals = F.signals()
        switch Int.random(in: 0..<20, using: &random) {
        case 0...2: signals.allowance = .missing
        case 3: signals.allowance = .invalid(.expired)
        default:
            signals.allowance = .valid(expiresAt: F.at(atMs + Int64.random(in: -500...12_000, using: &random)).wall)
        }
        if Int.random(in: 0..<5, using: &random) == 0 {
            let signal = PlatformSignal.allCases[Int.random(in: 0..<PlatformSignal.allCases.count, using: &random)]
            signals.readings[signal] = Bool.random(using: &random) ? .present : .uncertain
        }
        if Int.random(in: 0..<10, using: &random) == 0 {
            signals.ownInput = OwnInputActivity(
                commandFromPostedEvent: true, operationExecuting: false, lastPostedEvent: nil)
        }
        let command: ArmingCommand? =
            switch Int.random(in: 0..<20, using: &random) {
            case 0...9: nil
            case 10...14: .arm(for: .milliseconds(Int64.random(in: 1...15_000, using: &random)))
            case 15, 16: .disarm
            case 17, 18: .killSwitch
            default: .arm(for: .zero)
            }
        return (signals, command)
    }

    /// The offsets after `after` and through `through` at which `report`, reduced from `signals`,
    /// changes by the clock alone, earliest first.
    private static func expiryOffsets(of report: StateReport, signals: StateSignals, after: Int64, through: Int64)
        -> [Int64]
    {
        var offsets: Set<Int64> = []
        if case .armed(let until) = report.arming {
            offsets.insert(Int64((F.t0.monotonic.duration(to: until) / .milliseconds(1)).rounded()))
        }
        if case .valid(let expiresAt) = signals.allowance {
            offsets.insert(expiresAt.millisecondsSinceEpoch - F.t0.wall.millisecondsSinceEpoch)
        }
        return offsets.filter { $0 > after && $0 <= through }.sorted()
    }
}
