import DeskhandCore
import Testing

/// Contract 6.5: a `press` posts the key it names under the layout it was checked against. A layout
/// that changes after step 2 is a fault before any down event it would change.
@Suite("Executor: the keyboard layout")
struct LayoutTests {
    @Test("a layout that lost the key before the last look fails the call with 0 events")
    func layoutChangedBeforeLastLook() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        await harness.onLog(.intent) { mac.change { $0.missingKeys = [.k] } }
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "modifiers": ["shift"]]))
        #expect(answer.code == .internalError)
        #expect(answer.operation == OperationView(status: .failed, eventsPosted: 0))
        #expect(mac.posted.isEmpty)
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("a layout change between a modifier and the key fails before the key-down, and releases")
    func layoutChangedBeforeKeyDown() async throws {
        let mac = FakeMac { $0.afterPost[1] = { world, _ in world.missingKeys = [.k] } }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "modifiers": ["shift"]]))
        #expect(answer.code == .internalError)
        #expect(answer.operation == OperationView(status: .failed, eventsPosted: 1))
        #expect(mac.posted == [.modifierDown(ExecutorFixture.modifierCodes[.shift]!)])
        #expect(mac.released == [.modifierKey(.shift)])
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("a layout change while the key is held changes nothing: the key that went down comes up")
    func layoutChangedDuringHold() async throws {
        let mac = FakeMac()
        mac.change { $0.onSleep = { mac.change { $0.missingKeys = [.k] } } }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "hold_ms": 200]))
        #expect(answer.result?.eventsPosted == 2)
        #expect(mac.posted.last == .keyUp(ExecutorFixture.code(.k), text: nil))
    }
}
