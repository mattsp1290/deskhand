import DeskhandCore
import Testing

@testable import DeskhandServer

@Suite("lease")
struct LeaseToolTests {
    @Test("acquire, renew and release follow the table of contract 5.1")
    func operations() async throws {
        let harness = try ToolHarness()
        let other = ToolFixture.otherHolder

        #expect(try await harness.lease(.renew(ttlMs: 30_000)).result.outcome == .refused(.leaseNotHeld))
        #expect(try await harness.lease(.release).result.outcome == .notHeld)

        let acquired = try await harness.lease(.acquire(ttlMs: 20_000))
        #expect(acquired.result.outcome == .acquired)
        #expect(
            acquired.lease
                == .heldByCaller(
                    acquiredAt: ToolFixture.t0.wall, expiresAt: ToolFixture.t0.wall.adding(milliseconds: 20_000),
                    expiresInMs: 20_000))

        harness.clock.advance(byMilliseconds: 5000)
        #expect(try await harness.lease(.acquire(ttlMs: 30_000)).result.outcome == .renewed)
        let renewed = try await harness.lease(.renew(ttlMs: 10_000))
        #expect(renewed.result.outcome == .renewed)
        #expect(renewed.lease.heldByCaller)

        let refused = try await harness.lease(.acquire(ttlMs: 30_000), holder: other)
        #expect(refused.result.outcome == .refused(.leaseHeldByOther(expiresInMs: 10_000)))
        #expect(refused.lease == .notHeldByCaller)
        #expect(try await harness.lease(.renew(ttlMs: 30_000), holder: other).result.outcome == refused.result.outcome)
        #expect(try await harness.lease(.release, holder: other).result.outcome == refused.result.outcome)

        let released = try await harness.lease(.release)
        #expect(released.result.outcome == .released)
        #expect(released.lease == .notHeldByCaller)
        #expect(try await harness.lease(.renew(ttlMs: 30_000)).result.outcome == .refused(.leaseNotHeld))
        #expect(try await harness.lease(.acquire(ttlMs: 30_000), holder: other).result.outcome == .acquired)
        #expect(harness.leaseChanges.value == 11)
    }

    @Test("a lease that ran out is lease_expired for its holder only")
    func expiry() async throws {
        let harness = try ToolHarness()
        try await harness.lease(.acquire(ttlMs: 5000))
        harness.clock.advance(byMilliseconds: 5000)
        #expect(try await harness.lease(.renew(ttlMs: 5000)).result.outcome == .refused(.leaseExpired))
        #expect(
            try await harness.lease(.renew(ttlMs: 5000), holder: ToolFixture.otherHolder).result.outcome
                == .refused(.leaseNotHeld))
        #expect(try await harness.lease(.release).result.outcome == .notHeld)
        #expect(try await harness.lease(.acquire(ttlMs: 5000)).result.outcome == .acquired)
    }

    @Test(
        "gated, paused and disarmed refuse acquire and renew in the result and allow release",
        arguments: [[BlockingState.gated], [.paused, .disarmed], [.disarmed]])
    func droppingStates(states: Set<BlockingState>) async throws {
        let harness = try ToolHarness()
        try await harness.lease(.acquire(ttlMs: 30_000))
        let reduction = harness.hold(states)
        #expect(reduction.leaseEnds.count == 1)
        let state = try #require(ActiveStates(states).current.blocking?.leaseDropping)
        #expect(reduction.interruptions.contains(.leaseEnded(reduction.leaseEnds[0])))

        for command in [LeaseCommand.acquire(ttlMs: 30_000), .renew(ttlMs: 30_000)] {
            let result = try await harness.lease(command)
            #expect(result.result.outcome == .refused(.state(state)))
            #expect(result.result.jsonValue["code"]?.stringValue == state.rawValue)
            #expect(result.lease == .notHeldByCaller)
        }
        #expect(try await harness.lease(.release).result.outcome == .notHeld)
    }

    @Test("the other blocking states leave the lease alone", arguments: [BlockingState.locked, .secureInput])
    func otherStates(state: BlockingState) async throws {
        let harness = try ToolHarness()
        try await harness.lease(.acquire(ttlMs: 30_000))
        #expect(harness.hold([state]).leaseEnds.isEmpty)
        #expect(try await harness.lease(.renew(ttlMs: 30_000)).result.outcome == .renewed)
        #expect(
            try await harness.lease(.acquire(ttlMs: 30_000), holder: ToolFixture.otherHolder).lease == .notHeldByCaller)
    }

    @Test("arming that ran out drops the lease before the next reduction does")
    func armingRunsOut() async throws {
        let harness = try ToolHarness()
        harness.clock.advance(byMilliseconds: 3_590_000)
        try await harness.lease(.acquire(ttlMs: 30_000))
        harness.clock.advance(byMilliseconds: 10_000)
        let status = try await harness.status(StatusArguments(holderID: ToolFixture.holder))
        #expect(status.activeStates.current == .disarmed)
        #expect(status.lease == .notHeldByCaller)
        #expect(try await harness.lease(.renew(ttlMs: 30_000)).result.outcome == .refused(.state(.disarmed)))
        #expect(try await harness.lease(.release).result.outcome == .notHeld)
    }

    @Test("no result names a holder, and held_by_caller is never another holder's lease")
    func noLeak() async throws {
        let harness = try ToolHarness()
        try await harness.lease(.acquire(ttlMs: 30_000))
        let callers = [
            (ToolFixture.caller, ToolFixture.otherHolder), (ToolFixture.otherCaller, ToolFixture.holder),
            (ToolFixture.otherCaller, ToolFixture.otherHolder),
        ]
        for (caller, holder) in callers {
            for command in [LeaseCommand.acquire(ttlMs: 30_000), .renew(ttlMs: 30_000), .release] {
                let result = try await harness.lease(command, holder: holder, caller: caller)
                #expect(result.lease == .notHeldByCaller)
                #expect(!containsHolderID(result.jsonValue))
            }
            let status = try await harness.status(StatusArguments(holderID: holder), caller: caller)
            #expect(status.lease == .notHeldByCaller)
            #expect(!containsHolderID(status.jsonValue))
        }
    }

    private func containsHolderID(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let members):
            members.keys.contains("holder_id") || members.values.contains(where: containsHolderID)
        case .array(let items): items.contains(where: containsHolderID)
        default: false
        }
    }
}
