import DeskhandCore
import Testing

@Suite("Executor: the action ceiling", .timeLimit(.minutes(1)))
struct CeilingTests {
    @Test(
        "a denied_app or denied_shortcut refusal before admission counts toward the ceiling", arguments: [true, false])
    func policyRefusalsCount(deniedApp: Bool) async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac, actionsPerMinute: 2)
        let refused: JSONValue
        if deniedApp {
            mac.change { $0.focus = ObservedWindow(owner: ExecutorFixture.terminal, title: "zsh") }
            refused = ["type": "type", "text": "x"]
        } else {
            refused = ["type": "press", "key": "space", "modifiers": ["command"]]
        }
        let expected: ToolErrorCode = deniedApp ? .deniedApp : .deniedShortcut
        #expect(await harness.executor.perform(try harness.keyboard(refused, operation: "op-1")).code == expected)
        #expect(await harness.executor.perform(try harness.keyboard(refused, operation: "op-2")).code == expected)
        let third = await harness.executor.perform(try harness.keyboard(refused, operation: "op-3"))
        #expect(third.code == .rateLimited)
    }

    @Test("a replay does not count toward the ceiling")
    func replayDoesNotCount() async throws {
        let harness = try Harness(actionsPerMinute: 2)
        let call = try harness.keyboard(["type": "type", "text": "x"])
        #expect(await harness.executor.perform(call).result != nil)
        for _ in 0..<3 {
            guard case .replayed = await harness.executor.perform(call) else {
                Issue.record("not a replay")
                return
            }
        }
        let second = await harness.executor.perform(
            try harness.keyboard(["type": "type", "text": "x"], operation: "op-2"))
        #expect(second.result != nil, "the second new call got \(String(describing: second.code))")
        let third = await harness.executor.perform(
            try harness.keyboard(["type": "type", "text": "x"], operation: "op-3"))
        #expect(third.code == .rateLimited)
    }
}
