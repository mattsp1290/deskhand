import DeskhandCore
import Testing

/// Contract 12.3 steps 5 and 6: the checks before every event, the last look first among them, with
/// nothing slow between the reads of the state, the lease, the person and the connection and the
/// post.
@Suite("Executor: the checks before every event", .timeLimit(.minutes(1)))
struct LastLookTests {
    /// A change of the world that a check must catch.
    enum Change: String, CaseIterable, Sendable {
        case paused, userActive, leaseReleased, leaseExpired, deniedWindow, frontmostDenied, focusDenied

        var code: ToolErrorCode {
            switch self {
            case .paused: .paused
            case .userActive: .userActive
            case .leaseReleased: .leaseNotHeld
            case .leaseExpired: .leaseExpired
            case .deniedWindow, .frontmostDenied, .focusDenied: .deniedApp
            }
        }

        /// The changes a check reads after the identities, which an identity read can outlast.
        static let fast: [Change] = [.paused, .userActive, .leaseReleased, .leaseExpired]

        func apply(_ world: inout FakeMac.World, at now: ClockReading) {
            switch self {
            case .paused: world.report = ExecutorFixture.report([.paused], at: now)
            case .userActive: world.idleMs = 3
            case .leaseReleased:
                _ = world.lease.apply(
                    .init(holderID: ExecutorFixture.holder, command: .release), principal: ExecutorFixture.principal,
                    state: .ok, now: now)
            case .leaseExpired: world.offsetMs += 6_000
            case .deniedWindow: world.windows = { _ in ObservedWindow(owner: ExecutorFixture.terminal, title: "zsh") }
            case .frontmostDenied: world.frontmost = ExecutorFixture.terminal
            case .focusDenied: world.focus = ObservedWindow(owner: ExecutorFixture.terminal, title: "zsh")
            }
        }
    }

    @Test(
        "a change while the identities are read is seen before the post, at the last look and later",
        arguments: Change.fast, [0, 1])
    func changeDuringIdentityRead(_ change: Change, afterEvent: Int) async throws {
        let mac = FakeMac { $0.lease = ExecutorFixture.acquired(ttlMs: 5_000) }
        let harness = try Harness(mac: mac)
        let arm: FakeMac.Change = { world, _ in
            world.duringIdentityRead = { world, now in change.apply(&world, at: now) }
        }
        if afterEvent == 0 {
            await harness.onLog(.intent) {
                let now = mac.reading
                mac.change { arm(&$0, now) }
            }
        } else {
            mac.change { $0.afterPost[afterEvent] = arm }
        }
        let answer = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "abc"]))
        #expect(answer.code == change.code)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: afterEvent))
        #expect(mac.posted.count == afterEvent, "an event went out after \(change) during the identity read")
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    static let actions: [JSONValue] = [
        ["type": "press", "key": "k", "modifiers": ["shift", "command"], "hold_ms": 150],
        ["type": "type", "text": "abc"],
        ["type": "click", "x": 30, "y": 30, "count": 2, "modifiers": ["option"]],
        ["type": "drag", "path": [["x": 3, "y": 3], ["x": 60, "y": 9]], "duration_ms": 120, "modifiers": ["shift"]],
        ["type": "scroll", "x": 9, "y": 9, "dy": 400],
    ]

    @Test(
        "before every post: the ledger write, the identities, then the state and the person, then the post",
        arguments: actions)
    func orderBeforeEveryPost(action: JSONValue) async throws {
        let mac = FakeMac()
        let recorder = TouchRecorder(mac)
        let harness = try Harness(mac: mac, overrides: recorder.overrides)
        let isKeyboard = action["type"] == "press" || action["type"] == "type"
        let call = try isKeyboard ? harness.keyboard(action) : harness.pointer(action)
        #expect(await harness.executor.perform(call).result != nil)
        let touches = recorder.all
        var posts = 0
        for (index, touch) in touches.enumerated() where touch == .post {
            posts += 1
            // The checks of this event: everything since the previous post or ledger write.
            var start = index
            while start > 0, touches[start - 1] != .post, touches[start - 1] != .ledgerWrite { start -= 1 }
            let checks = Array(touches[start..<index])
            let lastIdentity = try #require(checks.lastIndex(of: .identity), "post \(posts): no identity read")
            let afterIdentity = Set(checks[(lastIdentity + 1)...])
            #expect(
                afterIdentity.isSuperset(of: [.snapshot, .activity]),
                "post \(posts): \(checks) does not read the state and the person after the identities")
        }
        #expect(posts == mac.posted.count)
    }

    @Test(
        "a change between admission and the first event is caught by the last look", arguments: Change.allCases,
        [true, false])
    func lastLookCatches(_ change: Change, keyboard: Bool) async throws {
        if change == .deniedWindow && keyboard { return }
        if change == .focusDenied && !keyboard { return }
        let mac = FakeMac { $0.lease = ExecutorFixture.acquired(ttlMs: 5_000) }
        let harness = try Harness(mac: mac)
        await harness.onLog(.intent) {
            let now = mac.reading
            mac.change { change.apply(&$0, at: now) }
        }
        let call =
            try keyboard
            ? harness.keyboard(["type": "press", "key": "k", "modifiers": ["shift"]])
            : harness.pointer(["type": "move", "x": 20, "y": 20])
        let answer = await harness.executor.perform(call)
        #expect(answer.code == change.code)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 0))
        #expect(mac.posted.isEmpty, "posted \(mac.posted)")
        #expect(mac.released.isEmpty)
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(answer.structuredContent?["measured"] != nil)
    }

    @Test("a last look that fails withdraws the entry it wrote: nothing posted, nothing released")
    func lastLookWithdraws() async throws {
        let harness = try Harness()
        // Open for step 3 and the look before the record; closed at the last look.
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "type", "text": "ab"], connection: FakeConnection(openReads: 2)))
        #expect(answer.code == .cancelled)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 0))
        #expect(harness.mac.posted.isEmpty)
        #expect(harness.mac.released.isEmpty)
        let writes = harness.mac.read(\.trace).compactMap { entry -> [HeldInput]? in
            guard case .ledger(let entries) = entry else { return nil }
            return entries
        }
        #expect(writes == [[.key(ExecutorFixture.carrier)], []])
        #expect(await harness.executor.isInSection == false)
    }

    @Test("a success reports what the last look measured, not what step 14 measured")
    func measuredFromTheLastLook() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        await harness.onLog(.intent) {
            mac.advance(byMilliseconds: 40)
            mac.change { $0.windows = { _ in ObservedWindow(owner: ExecutorFixture.notes, title: "list") } }
        }
        let result = try #require(
            await harness.executor.perform(try harness.pointer(["type": "move", "x": 20, "y": 20])).result)
        #expect(result.measured.targetApp?.bundleID == "com.apple.Notes")
        #expect(result.measured.windowTitle == "list")
        #expect(result.measured.measuredAt == ExecutorFixture.t0.wall.adding(milliseconds: 40))
    }

    @Test("an interruption during admission stops that call at its last look, and only that call")
    func interruptionDuringAdmission() async throws {
        let harness = try Harness()
        let executor = harness.executor
        await harness.onLog(.intent) { await executor.interrupt(.state(.paused)) }
        let first = await executor.perform(try harness.keyboard(["type": "type", "text": "x"]))
        #expect(first.code == .paused)
        #expect(first.operation == OperationView(status: .aborted, eventsPosted: 0))
        #expect(harness.mac.posted.isEmpty)
        #expect(harness.mac.ledgerOnDisk.isEmpty)
        await harness.onLog(.intent, nil)
        let second = await executor.perform(try harness.keyboard(["type": "type", "text": "y"], operation: "op-2"))
        #expect(second.result?.eventsPosted == 2)
    }
}
