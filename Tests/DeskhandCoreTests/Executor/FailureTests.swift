import DeskhandCore
import Testing

/// Faults and hang-ups: nothing is posted that was not first recorded (contract 12.3), and a call
/// whose connection closed before admission is dropped (contract 9.5).
@Suite("Executor: faults", .timeLimit(.minutes(1)))
struct FailureTests {
    @Test("an intent the log cannot commit refuses with log_unavailable: nothing posted, no record")
    func logUnavailable() async throws {
        let harness = try Harness()
        await harness.log.failEvery(.intent, with: .reject(.connectionRefused))
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 3, "y": 4]))
        #expect(answer.code == .logUnavailable)
        #expect(answer.operation == nil)
        #expect(answer.structuredContent?["measured"]?["target_app"]?["bundle_id"] == "com.apple.TextEdit")
        #expect(answer.structuredContent?["measured"]?["window_title"] == "notes.txt")
        #expect(harness.mac.posted.isEmpty)
        #expect(try await harness.status() == .notFound)
        #expect(harness.mac.read(\.logAppends).first == false)
    }

    @Test("a record file that cannot be loaded refuses every effect with internal_error until it loads")
    func storeUnavailable() async throws {
        let loader = FakeStoreLoader()
        loader.failNextLoad = true
        let harness = try Harness(loader: loader)
        #expect(await harness.executor.storesAvailable == false)
        let answer = await harness.executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1]))
        #expect(answer.code == .internalError)
        #expect(answer.operation == nil)
        #expect(harness.mac.posted.isEmpty)
        #expect(await harness.executor.reloadUnavailableStores())
        #expect(await harness.executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1])).result != nil)
    }

    @Test("a failed write of executing posts nothing and fails the call; the record is recovered on reload")
    func executingWriteFails() async throws {
        let loader = FakeStoreLoader()
        // The load's replace crosses boundaries 0 to 3, admission's append and flush 4 and 5.
        loader.faultAt = 6
        let harness = try Harness(loader: loader)
        let call = try harness.keyboard(["type": "type", "text": "hi"])
        let answer = await harness.executor.perform(call)
        #expect(answer.code == .internalError)
        #expect(answer.operation == OperationView(status: .failed, eventsPosted: 0))
        #expect(harness.mac.posted.isEmpty)
        #expect(await harness.executor.storesAvailable == false)
        #expect(
            await harness.executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-2"))
                .code == .internalError)

        #expect(await harness.executor.reloadUnavailableStores())
        #expect(try await harness.status() == .found(OperationView(status: .failedBeforeExecution, eventsPosted: 0)))
        let repeated = await harness.executor.perform(call)
        #expect(repeated.structuredContent?["code"] == "interrupted")
        #expect(harness.mac.posted.isEmpty)
    }

    @Test("a ledger write that fails stops the call before the down event it guards")
    func ledgerWriteFails() async throws {
        let mac = FakeMac { $0.failLedgerWrites = true }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.pointer(["type": "click", "x": 3, "y": 4, "modifiers": ["shift"]]))
        #expect(answer.code == .internalError)
        #expect(answer.operation == OperationView(status: .failed, eventsPosted: 1))
        #expect(mac.posted == [.pointerMove(to: GlobalPoint(x: 3.5, y: 4.5), dragging: nil)])
        #expect(await harness.executor.storesAvailable == false)
        #expect(
            await harness.executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-2"))
                .code == .internalError)

        mac.change { $0.failLedgerWrites = false }
        #expect(await harness.executor.reloadUnavailableStores())
        #expect(
            await harness.executor.perform(try harness.pointer(["type": "move", "x": 1, "y": 1], operation: "op-3"))
                .result != nil)
    }

    @Test("an event that cannot be posted fails the call and releases what it pressed")
    func postFails() async throws {
        let mac = FakeMac { $0.failPostAt = 3 }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.pointer(["type": "click", "x": 3, "y": 4, "modifiers": ["shift"]]))
        #expect(answer.code == .internalError)
        #expect(answer.operation == OperationView(status: .failed, eventsPosted: 2))
        #expect(mac.released == [.button(.left), .modifierKey(.shift)])
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("a release that cannot be posted stays owed: cleanup_pending")
    func releaseFails() async throws {
        let mac = FakeMac {
            $0.failReleases = true
            $0.afterPost[2] = { world, _ in world.idleMs = 0 }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "a", "modifiers": ["command"], "hold_ms": 300]))
        #expect(answer.code == .userActive)
        #expect(mac.ledgerOnDisk == [.modifierKey(.command), .named(.a)])
        #expect(await harness.executor.owesReleases)
        mac.change {
            $0.failReleases = false
            $0.idleMs = 60_000
        }
        guard case .attempted(.complete) = await harness.executor.releaseOwedInput() else {
            Issue.record("the owed releases were not posted")
            return
        }
        #expect(mac.released == [.named(.a), .modifierKey(.command)])
    }

    @Test("a connection closed when the call reaches the section is dropped: nothing posted, no record")
    func closedBeforeSection() async throws {
        let harness = try Harness()
        let answer = await harness.executor.perform(
            try harness.pointer(["type": "move", "x": 1, "y": 1], connection: FakeConnection(openReads: 0)))
        guard case .dropped = answer else {
            Issue.record("not dropped: \(String(describing: answer.code))")
            return
        }
        #expect(harness.mac.posted.isEmpty)
        #expect(try await harness.status() == .notFound)
        #expect(await harness.logEntries.map(\.kind) == [.refusal])
    }

    @Test("a connection closed after the intent entry is dropped before the record exists")
    func closedAfterIntent() async throws {
        let harness = try Harness()
        let answer = await harness.executor.perform(
            try harness.pointer(["type": "move", "x": 1, "y": 1], connection: FakeConnection(openReads: 1)))
        guard case .dropped = answer else {
            Issue.record("not dropped: \(String(describing: answer.code))")
            return
        }
        #expect(harness.mac.posted.isEmpty)
        #expect(try await harness.status() == .notFound)
        let entries = await harness.logEntries
        #expect(entries.map(\.kind) == [.intent, .refusal])
        guard case .refusal(let refusal)? = entries.last else { return }
        #expect(refusal.code == .cancelled)
    }

    @Test("arguments that did not validate: the state first, then invalid_argument, each with the record")
    func unparsedArguments() async throws {
        let harness = try Harness()
        let call = try harness.pointer(["type": "move", "x": 1, "y": 1])
        #expect(await harness.executor.perform(call).result != nil)
        let handles = EffectHandles(arguments: [
            "holder_id": .string(ExecutorFixture.holder.rawValue), "operation_id": "op-1", "action": "bad",
        ])
        let error = ArgumentError(at: JSONPointer(["action"]), "must be an object")
        let invalid = await harness.executor.refusal(
            for: error, tool: .pointer, handles: handles, principal: ExecutorFixture.principal,
            nodeAddress: ExecutorFixture.node)
        #expect(invalid.code == .invalidArgument)
        #expect(invalid.operation == .existing(OperationView(status: .completed, eventsPosted: 1)))

        let paused = ExecutorFixture.report([.paused], at: harness.mac.reading)
        harness.mac.change { $0.report = paused }
        let blocked = await harness.executor.refusal(
            for: error, tool: .pointer, handles: handles, principal: ExecutorFixture.principal,
            nodeAddress: ExecutorFixture.node)
        #expect(blocked.code == .paused)
        #expect(blocked.state == .paused)
        #expect(blocked.operation == .existing(OperationView(status: .completed, eventsPosted: 1)))
    }
}
