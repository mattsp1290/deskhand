import DeskhandCore
import Testing

@testable import DeskhandServer

/// A restart in the middle of an operation (contract 12.9), from the files a crash leaves: the
/// record file and the ledger as they were on disk while a key was held.
@Suite("end to end: restart", .timeLimit(.minutes(2)))
struct RestartEndToEndTests {
    @Test("aborted_by_restart, interrupted on repeat, owed releases posted once cleanup is authorized")
    func restartDuringAnOperation() async throws {
        let clock = ToolClock()
        let first = try await DeskhandStack.start(.init(clock: clock))
        let frame: String
        let arguments: JSONObject
        let crashed: StateDirectory
        do {
            frame = try await first.ready()
            arguments = Wire.press("a", holdMs: 2000, frame: frame, "op-1")
            let (entered, proceed) = (Latch(), Latch())
            first.desk.change {
                $0.onSleep = {
                    entered.open()
                    await proceed.wait()
                }
            }
            let held = Task { try await first.call("keyboard", arguments) }
            await entered.wait()
            crashed = try first.state.copy()
            proceed.open()
            _ = try await held.value
        } catch {
            await first.stop()
            throw error
        }
        await first.stop()
        clock.advance(byMilliseconds: 10_000)

        try await DeskhandStack.with(.init(armed: false, states: [.locked], state: crashed, clock: clock)) { stack in
            let key = HeldInput.key(try #require(stack.desk.code(for: .a)))
            let operation = OperationKey(
                principal: Principal(certificateSubject: TestPKI.expectedSubject), holderID: HolderID(Wire.holder)!,
                operationID: OperationID("op-1")!)
            #expect(stack.recovery.operationRecords.restarted == [operation: .abortedByRestart])
            guard case .loaded(let left) = stack.recovery.heldInputLedger else {
                Issue.record("the ledger did not load: \(stack.recovery)")
                return
            }
            #expect(left == [key])
            #expect(stack.recovery.effectRefusal == .cleanupPending)
            #expect(stack.desk.released.isEmpty, "locked defers every release")

            let status = try await stack.call("status", ["holder_id": .string(Wire.holder)])
            #expect(status.structuredContent?["started_at"] == stack.startedAt.jsonValue)
            #expect(status.structuredContent?["started_at"] != first.startedAt.jsonValue)
            #expect(status.structuredContent?["lease"]?["held_by_caller"] == false)
            #expect(try await stack.activeStates() == ["disarmed", "locked"])
            #expect(try await stack.reportedConditions().contains("cleanup_pending"))
            let record = try #require(try await stack.lookUp("op-1"))
            #expect(record["status"] == "aborted_by_restart")
            // A lower bound: the count is not written while the operation runs (contract 12.9).
            guard case .number(let eventsPosted)? = record["events_posted"] else {
                Issue.record("no events_posted in \(record)")
                return
            }
            #expect(eventsPosted <= 1)

            // A start is disarmed, which outranks locked; the record still comes with the state's name.
            let blockedRepeat = try await stack.call("keyboard", arguments)
            ContractShape.expectToolError(blockedRepeat, "disarmed")
            #expect(blockedRepeat.operation == record)

            await stack.hold([])
            #expect(await eventually { stack.desk.released == [key] })
            #expect(try await eventually { !(try await stack.reportedConditions()).contains("cleanup_pending") })
            #expect(try await stack.activeStates() == ["disarmed"])

            await stack.arm()
            let repeated = try await stack.call("keyboard", arguments)
            ContractShape.expectToolError(repeated, "interrupted")
            #expect(repeated.structuredContent?["current_state"] == "ok")
            #expect(repeated.operation == record)

            #expect(try await stack.acquire().structuredContent?["lease_result"]?["outcome"] == "acquired")
            let stale = try await stack.call("keyboard", Wire.type("hi", frame: frame, "op-2"))
            ContractShape.expectToolError(stale, "stale_frame")
            #expect(stale.structuredContent?["details"]?["reason"] == "unknown")
            let fresh = try await stack.screenshot()
            #expect(
                try await stack.call("keyboard", Wire.type("hi", frame: fresh, "op-2")).structuredContent?["status"]
                    == "completed")
        }
    }
}
