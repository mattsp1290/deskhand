import DeskhandCore
import Synchronization
import Testing

@testable import DeskhandServer

@Suite("status")
struct StatusToolTests {
    static let everyState: [Set<BlockingState>] =
        [[]] + BlockingState.allCases.filter { $0 != .paused }.map { [$0] } + [
            [.paused, .disarmed], [.gated, .locked],
        ]

    @Test("answers in every state with the state, its precedence and the conditions", arguments: everyState)
    func answersInEveryState(states: Set<BlockingState>) async throws {
        let harness = try ToolHarness()
        harness.hold(states, conditions: [.loginWindow])
        let status = try await harness.status(StatusArguments(holderID: ToolFixture.holder))
        var expected = states
        expected.insert(.notConsole)
        if states.contains(.gated) { expected.insert(.disarmed) }
        #expect(status.activeStates == ActiveStates(expected))
        #expect(status.activeStates.current == ActiveStates(expected).current)
        #expect(status.conditions.contains(.loginWindow))
        #expect(status.lease == .notHeldByCaller)
        let json = status.jsonValue
        #expect(json["state"]?.stringValue == ActiveStates(expected).current.rawValue)
        #expect(json["holder_id"] == nil)
    }

    @Test("reports this Mac, the clock, the limits in force and the display generation")
    func reportsTheMac() async throws {
        let limits = Limits(frameMaxAgeMs: 30_000, actionsPerMinute: 20, operationRetentionMs: 3_600_000)
        let harness = try ToolHarness(limits: limits)
        harness.clock.advance(byMilliseconds: 1500)
        let status = try await harness.status()
        #expect(status.mac == "studio-mac")
        #expect(status.serverVersion == "0.1.0")
        #expect(status.time == ToolFixture.t0.wall.adding(milliseconds: 1500))
        #expect(status.startedAt == ToolFixture.t0.wall)
        #expect(status.limits == limits)
        #expect(status.displayConfigGeneration == ToolFixture.generation)
        #expect(status.armedUntil == ToolFixture.t0.wall.adding(milliseconds: 3_600_000))
        #expect(status.lease == nil)
        #expect(status.operation == nil)
        #expect(status.jsonValue["lease"] == .null)
        #expect(status.jsonValue["operation"] == nil)

        harness.displays.reconfigure()
        #expect(try await harness.status().displayConfigGeneration == DisplayConfigGeneration(5))
    }

    @Test("takes each condition from the one place that knows it now")
    func conditionsHaveOneSource() async throws {
        let warning = Mutex(true)
        let ledger = MemoryLedgerStore()
        var previous = try HeldInputLedger(store: ledger)
        _ = try previous.willPress(.key(PostedKeyCode(5)))
        let harness = try ToolHarness(ledger: ledger)
        let conditions = LiveConditions(credentialsWarning: { warning.withLock { $0 } })
        let dispatcher = DeskhandDispatcher(
            configuration: harness.dispatcher.configuration, owner: harness.owner, executor: harness.executor,
            platform: .init(
                capturer: harness.capturer, identity: harness.desk, activity: harness.desk, conditions: conditions),
            digestKey: ToolFixture.digestKey)
        harness.hold([], conditions: [.logUnavailable, .cleanupPending])
        conditions.actionLogDidAppend(succeeded: true)
        harness.desk.change { $0.idleMs = 60_000 }
        var status = try await dispatcher.status(StatusArguments(), caller: ToolFixture.caller)
        #expect(status.conditions == [.credentialsWarning, .cleanupPending])

        warning.withLock { $0 = false }
        conditions.actionLogDidAppend(succeeded: false)
        harness.desk.change { $0.idleMs = 2999 }
        status = try await dispatcher.status(StatusArguments(), caller: ToolFixture.caller)
        #expect(status.conditions == [.logUnavailable, .cleanupPending, .userActive])
        #expect(status.activeStates.current == .ok)

        harness.desk.change { $0.idleMs = nil }
        status = try await dispatcher.status(StatusArguments(), caller: ToolFixture.caller)
        #expect(status.conditions.contains(.userActive))
    }

    @Test("shows the lease only as the named holder sees it")
    func leaseView() async throws {
        let harness = try ToolHarness()
        try await harness.lease(.acquire(ttlMs: 10_000))
        harness.clock.advance(byMilliseconds: 4000)

        let own = try await harness.status(StatusArguments(holderID: ToolFixture.holder)).lease
        #expect(
            own
                == .heldByCaller(
                    acquiredAt: ToolFixture.t0.wall, expiresAt: ToolFixture.t0.wall.adding(milliseconds: 10_000),
                    expiresInMs: 6000))
        let other = try await harness.status(StatusArguments(holderID: ToolFixture.otherHolder))
        #expect(other.lease == .notHeldByCaller)
        #expect(other.jsonValue["lease"] == ["held_by_caller": false])
        let otherPrincipal = try await harness.status(
            StatusArguments(holderID: ToolFixture.holder), caller: ToolFixture.otherCaller)
        #expect(otherPrincipal.lease == .notHeldByCaller)

        harness.clock.advance(byMilliseconds: 6000)
        #expect(try await harness.status(StatusArguments(holderID: ToolFixture.holder)).lease == .notHeldByCaller)
    }

    @Test("never touches the lease")
    func neverTouchesTheLease() async throws {
        let harness = try ToolHarness()
        try await harness.lease(.acquire(ttlMs: 5000))
        harness.clock.advance(byMilliseconds: 6000)
        _ = try await harness.status(StatusArguments(holderID: ToolFixture.holder))
        let renewed = try await harness.lease(.renew(ttlMs: 5000))
        #expect(renewed.result.outcome == .refused(.leaseExpired))
    }

    @Test("looks an operation up without executing anything, in every state")
    func operationLookup() async throws {
        let harness = try ToolHarness()
        let query = OperationQuery(holderID: ToolFixture.holder, operationID: OperationID("op-1")!)
        #expect(try await harness.status(StatusArguments(operation: query)).operation == .notFound)
        #expect(try await harness.status(StatusArguments(operation: query)).jsonValue["operation"] == .null)

        try await harness.lease(.acquire(ttlMs: 30_000))
        let frame = try await harness.screenshot().result.frameID
        let answer = try await harness.type("hi", frame: frame)
        guard case .completed(let result) = answer else {
            Issue.record("expected a completed call, got \(answer)")
            return
        }
        let found = StatusOperation.found(OperationView(status: .completed, eventsPosted: result.eventsPosted))
        #expect(try await harness.status(StatusArguments(operation: query)).operation == found)

        harness.hold([.locked])
        #expect(try await harness.status(StatusArguments(operation: query)).operation == found)
        let otherHolder = OperationQuery(holderID: ToolFixture.otherHolder, operationID: OperationID("op-1")!)
        #expect(try await harness.status(StatusArguments(operation: otherHolder)).operation == .notFound)
        #expect(
            try await harness.status(StatusArguments(operation: query), caller: ToolFixture.otherCaller).operation
                == .notFound)
        #expect(harness.desk.posted.count == result.eventsPosted)
    }
}
