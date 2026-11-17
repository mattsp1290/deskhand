import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct TransitionEffectTests {
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

    static let rows: [Row] = [
        Row("ok stays ok", [], [], []),
        Row("screen locks", [], [.locked], leavingOK(.locked)),
        Row("console switch", [], [.notConsole], leavingOK(.notConsole)),
        Row("display sleeps", [], [.displayAsleep], leavingOK(.displayAsleep)),
        Row("permission revoked", [], [.permissionMissing], leavingOK(.permissionMissing)),
        Row("capture goes blank", [], [.permissionStale], leavingOK(.permissionStale)),
        Row("secure input on", [], [.secureInput], leavingOK(.secureInput)),
        Row("allowance withdrawn", [], [.gated], leavingOK(.gated) + [.dropLease(.gated, at: F.t0)]),
        Row("arming runs out", [], [.disarmed], leavingOK(.disarmed) + [.dropLease(.disarmed, at: F.t0)]),
        Row("kill switch", [], [.paused, .disarmed], leavingOK(.paused) + [.dropLease(.paused, at: F.t0)]),
        Row("two states at once name the higher", [], [.secureInput, .locked], leavingOK(.locked)),
        Row("gate and lock at once", [], [.locked, .gated], leavingOK(.gated) + [.dropLease(.gated, at: F.t0)]),
        Row("unlock restores nothing", [.locked], [], []),
        Row("allowance returns restores nothing", [.gated], [], []),
        Row("re-armed after kill switch", [.paused, .disarmed], [], []),
        Row("locked then gated", [.locked], [.locked, .gated], [.dropLease(.gated, at: F.t0)]),
        Row("lock gives way to gate", [.locked], [.gated], [.dropLease(.gated, at: F.t0)]),
        Row("arming runs out while gated", [.gated], [.gated, .disarmed], [.dropLease(.disarmed, at: F.t0)]),
        Row("kill switch while disarmed", [.disarmed], [.paused, .disarmed], [.dropLease(.paused, at: F.t0)]),
        Row(
            "gate withdrawn while paused", [.paused, .disarmed], [.gated, .paused, .disarmed],
            [.dropLease(.gated, at: F.t0)]),
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
        let (report, effects) = F.reduce(previous, F.signals(holding: row.to), command)
        #expect(report.activeStates(at: F.t0).states == row.to)
        #expect(effects == row.effects)
    }

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
                let (report, effects) = F.reduce(reports[fromIndex], to.signals, command)

                var expected: [TransitionEffect] = []
                if from.states.isEmpty, let highest = contractPrecedence.first(where: to.states.contains) {
                    expected = [.cancelInFlight(highest), .releaseHeldInput, .invalidateFrames]
                }
                if let dropping = contractPrecedence.first(where: {
                    leaseDroppingStates.contains($0) && to.states.contains($0) && !from.states.contains($0)
                }) {
                    expected.append(.dropLease(dropping.leaseDropping!, at: F.t0))
                }
                if report.activeStates(at: F.t0).states != to.states || effects != expected {
                    mismatches += 1
                    if samples.count < 3 { samples.append("\(from.states) -> \(to.states): \(effects)") }
                }
                checked += 1
            }
        }

        #expect(reachable.count == 384)
        #expect(reports.map { $0.activeStates(at: F.t0).states } == reachable.map(\.states))
        #expect(checked == 384 * 384 - 128 * 128)
        #expect(mismatches == 0, "first mismatches: \(samples)")
    }

    @Test(arguments: [[], [Condition.credentialsWarning, .cleanupPending, .logUnavailable]] as [Set<Condition>])
    func conditionsHaveNoEffects(_ before: Set<Condition>) throws {
        let all: Set<Condition> = [.credentialsWarning, .cleanupPending, .logUnavailable]
        let after = all.subtracting(before)
        for states in [[], [.locked], [.gated, .disarmed]] as [Set<BlockingState>] {
            let previous = try #require(F.report(holding: states, conditions: before))
            let (report, effects) = F.reduce(previous, F.signals(holding: states, conditions: after))
            #expect(report.conditions == after)
            #expect(report.activeStates(at: F.t0) == previous.activeStates(at: F.t0))
            #expect(effects.isEmpty)
        }
    }
}
