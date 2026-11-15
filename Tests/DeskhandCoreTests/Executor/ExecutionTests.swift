import DeskhandCore
import Testing

/// Contract 12.2 to 12.8: posting, the ledger, aborts, releases and the record.
@Suite("Executor: execution", .timeLimit(.minutes(1)))
struct ExecutionTests {
    static let chord: JSONValue = [
        "type": "press", "key": "k", "modifiers": ["shift", "control", "option"], "hold_ms": 500,
    ]
    /// Pressed control, option, shift, then k.
    static let chordReleases: [HeldInput] = [
        .named(.k), .modifierKey(.shift), .modifierKey(.option), .modifierKey(.control),
    ]

    @Test("a completed click: every event posted, the record and both log entries")
    func completedClick() async throws {
        let harness = try Harness()
        let answer = await harness.executor.perform(
            try harness.pointer(["type": "click", "x": 100, "y": 100, "count": 2, "modifiers": ["shift"]]))
        let result = try #require(answer.result)
        #expect(result.eventsPosted == 7)
        #expect(result.replayed == false)
        #expect(result.measured.frontmostApp.bundleID == "com.apple.TextEdit")
        #expect(result.measured.windowTitle == "notes.txt")
        #expect(result.measured.globalPoint == GlobalPoint(x: 100.5, y: 100.5))
        #expect(harness.mac.posted.count == 7)
        #expect(harness.mac.released.isEmpty)
        #expect(harness.mac.ledgerOnDisk.isEmpty)
        #expect(try await harness.status() == .found(OperationView(status: .completed, eventsPosted: 7)))
        let kinds = await harness.logEntries.map(\.kind)
        #expect(kinds == [.intent, .outcome])
        guard case .outcome(let outcome)? = await harness.logEntries.last else { return }
        #expect(outcome.outcome == .completed(eventsPosted: 7))
        #expect(harness.mac.read(\.executionChanges) == [true, false])
    }

    static let pointerActions: [(JSONValue, Int)] = [
        (["type": "move", "x": 1, "y": 2], 1),
        (["type": "scroll", "x": 1, "y": 2, "dy": 300], 4),
        (["type": "click", "x": 1, "y": 2, "count": 3, "modifiers": ["command", "option"]], 11),
        (["type": "drag", "path": [["x": 0, "y": 0], ["x": 0, "y": 0]], "duration_ms": 50], 3),
    ]

    @Test("events_posted counts every posted event", arguments: pointerActions)
    func pointerCounts(action: JSONValue, events: Int) async throws {
        let harness = try Harness()
        let answer = await harness.executor.perform(try harness.pointer(action))
        #expect(answer.result?.eventsPosted == events)
        #expect(harness.mac.posted.count == events)
    }

    @Test("events_posted for keyboard: a pair per typed grapheme, a pair per pressed key")
    func keyboardCounts() async throws {
        let typed = try Harness()
        #expect(
            await typed.executor.perform(try typed.keyboard(["type": "type", "text": "héllo"])).result?.eventsPosted
                == 10)
        let pressed = try Harness()
        #expect(await pressed.executor.perform(try pressed.keyboard(Self.chord)).result?.eventsPosted == 8)
    }

    @Test("the ledger holds every down event's input before it is posted, and is empty after")
    func ledgerBeforeEveryDown() async throws {
        for action: JSONValue in [
            Self.chord, ["type": "type", "text": "ab"],
            ["type": "click", "x": 3, "y": 3, "count": 2, "modifiers": ["control", "command"]],
            ["type": "drag", "path": [["x": 3, "y": 3], ["x": 40, "y": 3]], "modifiers": ["option"]],
        ] {
            let harness = try Harness()
            let call =
                try action["path"] == nil && action["x"] == nil ? harness.keyboard(action) : harness.pointer(action)
            #expect(await harness.executor.perform(call).result != nil)
            var onDisk: [HeldInput] = []
            for entry in harness.mac.read(\.trace) {
                switch entry {
                case .ledger(let entries): onDisk = entries
                case .posted(let event):
                    if let input = event.press { #expect(onDisk.contains(input), "\(event) posted without an entry") }
                case .released: Issue.record("a completed action released \(entry)")
                }
            }
            #expect(onDisk.isEmpty, "\(action)")
        }
    }

    @Test("type writes the carrier's ledger entry once and clears it after the last character")
    func typeWritesOnce() async throws {
        let harness = try Harness()
        _ = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "hello"]))
        let writes = harness.mac.read(\.trace).compactMap { entry -> [HeldInput]? in
            guard case .ledger(let entries) = entry else { return nil }
            return entries
        }
        #expect(writes == [[.key(ExecutorFixture.carrier)], []])
    }

    @Test("leaving ok mid-operation aborts with the state's name and releases in reverse press order")
    func stateLeavesOk() async throws {
        let mac = FakeMac {
            $0.afterPost[4] = { world, now in world.report = ExecutorFixture.report([.paused], at: now) }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.keyboard(Self.chord))
        #expect(answer.code == .paused)
        #expect(answer.toolError?.state == .paused)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 4))
        #expect(mac.released == Self.chordReleases)
        #expect(mac.ledgerOnDisk.isEmpty)
        guard case .outcome(let outcome)? = await harness.logEntries.last else {
            Issue.record("no outcome entry")
            return
        }
        #expect(outcome.outcome == .aborted(.state(.paused), eventsPosted: 4))
    }

    @Test("the person at the Mac during a hold aborts with user_active at the next poll and releases")
    func userActiveDuringHold() async throws {
        let mac = FakeMac { $0.afterPost[4] = { world, _ in world.idleMs = 40 } }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.keyboard(Self.chord))
        #expect(answer.code == .userActive)
        #expect(answer.details == ["idle_ms": 40])
        #expect(mac.read(\.sleeps).count == 1, "the hold slept on past the person's input")
        #expect(mac.released == Self.chordReleases)
    }

    @Test("a lock defers the releases; cleanup_pending refuses until they are posted")
    func lockDefersReleases() async throws {
        let mac = FakeMac {
            $0.afterPost[4] = { world, now in world.report = ExecutorFixture.report([.locked], at: now) }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.keyboard(Self.chord))
        #expect(answer.code == .locked)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 4))
        #expect(mac.released.isEmpty)
        #expect(mac.ledgerOnDisk == Self.chordReleases.reversed())
        #expect(mac.read(\.cleanupPending).last == true)
        #expect(await harness.executor.owesReleases)

        mac.change { $0.report = ExecutorFixture.okReport }
        let refused = await harness.executor.perform(
            try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-2"))
        #expect(refused.code == .cleanupPending)

        let lockedAgain = ExecutorFixture.report([.locked], at: mac.reading)
        mac.change { $0.report = lockedAgain }
        guard case .attempted(.deferred(let blockers)) = await harness.executor.releaseOwedInput() else {
            Issue.record("released while locked")
            return
        }
        #expect(blockers == [.locked])
        let paused = ExecutorFixture.report([.paused], at: mac.reading)
        mac.change { $0.report = paused }
        guard case .attempted(.complete) = await harness.executor.releaseOwedInput() else {
            Issue.record("releases not posted while paused")
            return
        }
        #expect(mac.released == Self.chordReleases)
        #expect(mac.read(\.cleanupPending).last == false)
        mac.change { $0.report = ExecutorFixture.okReport }
        #expect(
            await harness.executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-3"))
                .result != nil)
    }

    enum LeaseChange: String, CaseIterable, Sendable {
        case expired, released, reacquired, otherHolder
    }

    @Test("the lease ending mid-operation aborts with the code of how it ended", arguments: LeaseChange.allCases)
    func leaseEnds(_ change: LeaseChange) async throws {
        let mac = FakeMac {
            $0.lease = ExecutorFixture.acquired(ttlMs: 5_000)
            $0.afterPost[4] = { world, now in
                let principal = ExecutorFixture.principal
                let holder = ExecutorFixture.holder
                switch change {
                case .expired: break
                case .released:
                    _ = world.lease.apply(
                        .init(holderID: holder, command: .release), principal: principal, state: .ok, now: now)
                case .reacquired:
                    _ = world.lease.apply(
                        .init(holderID: holder, command: .release), principal: principal, state: .ok, now: now)
                    _ = world.lease.apply(
                        .init(holderID: holder, command: .acquire(ttlMs: 30_000)), principal: principal, state: .ok,
                        now: now)
                case .otherHolder:
                    _ = world.lease.apply(
                        .init(holderID: holder, command: .release), principal: principal, state: .ok, now: now)
                    _ = world.lease.apply(
                        .init(holderID: HolderID("crew:beta")!, command: .acquire(ttlMs: 30_000)), principal: principal,
                        state: .ok, now: now)
                }
            }
        }
        let harness = try Harness(mac: mac)
        let action: JSONValue = [
            "type": "press", "key": "k", "modifiers": ["shift", "control", "option"], "hold_ms": 5000,
        ]
        let answer = await harness.executor.perform(try harness.keyboard(action))
        let expected: ToolErrorCode = change == .expired ? .leaseExpired : .leaseNotHeld
        #expect(answer.code == expected)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 4))
        #expect(mac.released == Self.chordReleases)
    }

    @Test("a renewal during a hold moves the deadline, so the operation completes")
    func renewalMovesDeadline() async throws {
        let mac = FakeMac {
            $0.lease = ExecutorFixture.acquired(ttlMs: 5_000)
            $0.afterPost[4] = { world, now in
                _ = world.lease.apply(
                    .init(holderID: ExecutorFixture.holder, command: .renew(ttlMs: 30_000)),
                    principal: ExecutorFixture.principal, state: .ok, now: now)
            }
        }
        let harness = try Harness(mac: mac)
        let action: JSONValue = [
            "type": "press", "key": "k", "hold_ms": 5000, "modifiers": ["shift", "control", "option"],
        ]
        #expect(await harness.executor.perform(try harness.keyboard(action)).result?.eventsPosted == 8)
    }

    @Test("a hold polls the checks at least every 100 ms")
    func holdPolls() async throws {
        let harness = try Harness()
        _ = await harness.executor.perform(try harness.keyboard(["type": "press", "key": "a", "hold_ms": 450]))
        let sleeps = harness.mac.read(\.sleeps)
        #expect(sleeps.allSatisfy { $0 <= .milliseconds(100) })
        #expect(sleeps.reduce(.zero, +) >= .milliseconds(450))
    }

    @Test("the watchdog's interruption stops a hold, the first in refusal order winning")
    func watchdogInterrupts() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        mac.change {
            $0.onSleep = {
                await executor.interrupt(.userActive(idleMs: 12))
                await executor.interrupt(.state(.disarmed))
            }
        }
        let answer = await executor.perform(try harness.keyboard(Self.chord))
        #expect(answer.code == .disarmed)
        #expect(answer.toolError?.state == .disarmed)
        #expect(mac.read(\.sleeps).count == 1, "the hold slept on past the interruption")
        #expect(mac.released == Self.chordReleases)
    }

    @Test("the end of a lease the operation does not run under does not stop it")
    func otherLeaseEnd() async throws {
        var manager = ExecutorFixture.acquired()
        let release = LeaseArguments(holderID: ExecutorFixture.holder, command: .release)
        let acquire = LeaseArguments(holderID: ExecutorFixture.holder, command: .acquire(ttlMs: 30_000))
        let principal = ExecutorFixture.principal
        _ = manager.apply(release, principal: principal, state: .ok, now: ExecutorFixture.t0)
        _ = manager.apply(acquire, principal: principal, state: .ok, now: ExecutorFixture.t0)
        let ended = try #require(
            manager.apply(release, principal: principal, state: .ok, now: ExecutorFixture.t0).ended)
        #expect(ended.lease.serial == 2)
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        mac.change { $0.onSleep = { await executor.interrupt(.leaseEnded(ended)) } }
        #expect(await executor.perform(try harness.keyboard(Self.chord)).result?.eventsPosted == 8)
        #expect(await executor.isInSection == false)
    }

    @Test("the patch check older than 250 ms at the first event ends the call with stale_frame and 0 events")
    func stalePatchCheck() async throws {
        let mac = FakeMac { $0.captureMs = 251 }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 9, "y": 9]))
        #expect(answer.code == .staleFrame)
        #expect(answer.details == ["reason": "pixels_changed", "point_index": 0])
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 0))
        #expect(answer.structuredContent?["measured"]?["frontmost_app"] != nil)
        #expect(mac.posted.isEmpty)
    }

    @Test("a repeat of a completed call is answered from the record and posts nothing")
    func replay() async throws {
        let harness = try Harness(actionsPerMinute: 1)
        let call = try harness.pointer(["type": "click", "x": 5, "y": 5])
        let first = await harness.executor.perform(call)
        let repeated = await harness.executor.perform(call)
        guard case .replayed(_, let content) = repeated else {
            Issue.record("not a replay: \(String(describing: repeated.code))")
            return
        }
        var expected = try #require(first.structuredContent?.objectValue)
        expected["replayed"] = true
        #expect(content == .object(expected))
        #expect(harness.mac.posted.count == 3)
        #expect(await harness.logEntries.count == 2)
    }

    @Test("a repeat of an aborted call replays its error with replayed and current_state")
    func replayAborted() async throws {
        let mac = FakeMac {
            $0.afterPost[2] = { world, now in world.report = ExecutorFixture.report([.secureInput], at: now) }
        }
        let harness = try Harness(mac: mac)
        let call = try harness.keyboard(["type": "type", "text": "secret"])
        #expect(await harness.executor.perform(call).code == .secureInput)
        let whileBlocked = await harness.executor.perform(call)
        #expect(whileBlocked.code == .secureInput)
        #expect(whileBlocked.toolError?.operation == .existing(OperationView(status: .aborted, eventsPosted: 2)))

        mac.change { $0.report = ExecutorFixture.okReport }
        let replayed = await harness.executor.perform(call)
        #expect(replayed.isError)
        #expect(replayed.structuredContent?["code"] == "secure_input")
        #expect(replayed.structuredContent?["state"] == "secure_input")
        #expect(replayed.structuredContent?["current_state"] == "ok")
        #expect(replayed.structuredContent?["replayed"] == true)
        #expect(mac.posted.count == 2)
    }

    @Test("the caller hanging up mid-operation aborts it; a repeat returns cancelled")
    func cancelledMidOperation() async throws {
        let harness = try Harness()
        let call = try harness.keyboard(
            ["type": "type", "text": "abcdef"], connection: FakeConnection(openReads: 5))
        let answer = await harness.executor.perform(call)
        #expect(answer.code == .cancelled)
        #expect(answer.operation?.status == .aborted)
        let repeated = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "abcdef"]))
        #expect(repeated.structuredContent?["code"] == "cancelled")
        #expect(repeated.structuredContent?["replayed"] == true)
    }
}
