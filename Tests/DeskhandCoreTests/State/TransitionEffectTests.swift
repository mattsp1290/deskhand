import DeskhandCore
import Testing

@Suite struct TransitionEffectTests {
    private typealias F = StateFixture

    struct Row: Sendable, CustomTestStringConvertible {
        let from: Set<BlockingState>
        let to: Set<BlockingState>
        let effects: [TransitionEffect]
        let testDescription: String

        init(_ description: String, _ from: Set<BlockingState>, _ to: Set<BlockingState>, _ effects: [TransitionEffect])
        {
            self.from = from
            self.to = to
            self.effects = effects
            testDescription = description
        }
    }

    private static func leavingOK(_ state: BlockingState) -> [TransitionEffect] {
        [.cancelInFlight(state), .releaseHeldInput, .invalidateFrames]
    }

    /// Contract 10.3 to 10.5, 13.1 and 15.1.
    static let rows: [Row] = [
        Row("ok stays ok", [], [], []),
        Row("screen locks", [], [.locked], leavingOK(.locked)),
        Row("console switch", [], [.notConsole], leavingOK(.notConsole)),
        Row("display sleeps", [], [.displayAsleep], leavingOK(.displayAsleep)),
        Row("permission revoked", [], [.permissionMissing], leavingOK(.permissionMissing)),
        Row("capture goes blank", [], [.permissionStale], leavingOK(.permissionStale)),
        Row("secure input on", [], [.secureInput], leavingOK(.secureInput)),
        Row("allowance withdrawn", [], [.gated], leavingOK(.gated) + [.dropLease]),
        Row("arming runs out", [], [.disarmed], leavingOK(.disarmed) + [.dropLease]),
        Row("kill switch", [], [.paused, .disarmed], leavingOK(.paused) + [.dropLease]),
        Row("two states at once name the higher", [], [.secureInput, .locked], leavingOK(.locked)),
        Row("gate and lock at once", [], [.locked, .gated], leavingOK(.gated) + [.dropLease]),
        Row("unlock restores nothing", [.locked], [], []),
        Row("allowance returns restores nothing", [.gated], [], []),
        Row("re-armed after kill switch", [.paused, .disarmed], [], []),
        Row("locked then gated", [.locked], [.locked, .gated], [.dropLease]),
        Row("lock gives way to gate", [.locked], [.gated], [.dropLease]),
        Row("arming runs out while gated", [.gated], [.gated, .disarmed], [.dropLease]),
        Row("kill switch while disarmed", [.disarmed], [.paused, .disarmed], [.dropLease]),
        Row("gate withdrawn while paused", [.paused, .disarmed], [.gated, .paused, .disarmed], [.dropLease]),
        Row("gate returns while disarmed", [.gated, .disarmed], [.disarmed], []),
        Row("lock while disarmed", [.disarmed], [.disarmed, .locked], []),
        Row("lock gives way to display sleep", [.locked], [.displayAsleep], []),
        Row("secure input on while locked", [.locked], [.locked, .secureInput], []),
    ]

    @Test(arguments: rows)
    func transitionTable(_ row: Row) throws {
        let previous = try #require(F.report(holding: row.from))
        let (from, to) = (try #require(F.arming(for: row.from)), try #require(F.arming(for: row.to)))
        guard case .reachable(let command) = F.step(from: from, to: to) else {
            Issue.record("no single reduction reaches \(row.to) from \(row.from)")
            return
        }
        let (report, effects) = StateReducer.reduce(
            previous: previous, signals: F.signals(holding: row.to), command: command, now: F.t0)
        #expect(report.activeStates.states == row.to)
        #expect(effects == row.effects)
    }

    /// Every pair of reachable sets of states, in one reduction each. Leaving `ok` cancels, releases
    /// and invalidates in that order, naming the new state; any of `gated`, `paused` and `disarmed`
    /// beginning drops the lease; nothing else has an effect.
    @Test func everyReachableTransition() {
        let reachable = everyBlockingSubset.compactMap { states in
            F.arming(for: states).map { (states: states, arming: $0, signals: F.signals(holding: states)) }
        }
        let reports = reachable.map { F.report(arming: $0.arming, signals: $0.signals) }
        var checked = 0
        var mismatches = 0
        var samples: [String] = []

        for (fromIndex, from) in reachable.enumerated() {
            for to in reachable {
                guard case .reachable(let command) = F.step(from: from.arming, to: to.arming) else { continue }
                let (report, effects) = StateReducer.reduce(
                    previous: reports[fromIndex], signals: to.signals, command: command, now: F.t0)

                var expected: [TransitionEffect] = []
                if from.states.isEmpty, let highest = contractPrecedence.first(where: to.states.contains) {
                    expected = [.cancelInFlight(highest), .releaseHeldInput, .invalidateFrames]
                }
                if !to.states.subtracting(from.states).isDisjoint(with: leaseDroppingStates) {
                    expected.append(.dropLease)
                }
                if report.activeStates.states != to.states || effects != expected {
                    mismatches += 1
                    if samples.count < 3 { samples.append("\(from.states) -> \(to.states): \(effects)") }
                }
                checked += 1
            }
        }

        #expect(reachable.count == 384)
        #expect(reports.map(\.activeStates.states) == reachable.map(\.states))
        #expect(checked == 384 * 384 - 128 * 128)
        #expect(mismatches == 0, "first mismatches: \(samples)")
    }

    /// Contract 11: a condition never changes the state, never drops the lease and never
    /// invalidates a frame.
    @Test(arguments: [[], [Condition.credentialsWarning, .cleanupPending, .logUnavailable]] as [Set<Condition>])
    func conditionsHaveNoEffects(_ before: Set<Condition>) throws {
        let all: Set<Condition> = [.credentialsWarning, .cleanupPending, .logUnavailable]
        let after = all.subtracting(before)
        for states in [[], [.locked], [.gated, .disarmed]] as [Set<BlockingState>] {
            let previous = try #require(F.report(holding: states, conditions: before))
            let (report, effects) = StateReducer.reduce(
                previous: previous, signals: F.signals(holding: states, conditions: after), now: F.t0)
            #expect(report.conditions == after)
            #expect(report.activeStates == previous.activeStates)
            #expect(effects.isEmpty)
        }
    }
}
