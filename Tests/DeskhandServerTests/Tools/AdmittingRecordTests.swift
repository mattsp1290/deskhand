import DeskhandCore
import Testing

@testable import DeskhandServer

@Suite("effect errors and a call still in admission", .timeLimit(.minutes(1)))
struct AdmittingRecordTests {
    @Test("a call in admission is accepted to status, but gives the dispatcher's errors no operation")
    func admittingCallHasNoRecord() async throws {
        let (harness, frame) = try await EffectToolTests.ready()
        let (entered, proceed) = (Latch(), Latch())
        harness.desk.change {
            $0.onVerify = {
                entered.open()
                await proceed.wait()
            }
        }
        let raw: JSONObject = [
            "holder_id": .string(ToolFixture.holder.rawValue), "frame_id": .string(frame.rawValue),
            "operation_id": "op-1", "action": ["type": "click", "x": 100, "y": 100],
        ]
        let admitting = Task {
            await harness.dispatcher.effect(
                .pointer(try PointerArguments(arguments: raw)), received: raw, caller: ToolFixture.caller)
        }
        await entered.wait()

        let query = OperationQuery(holderID: ToolFixture.holder, operationID: OperationID("op-1")!)
        let accepted = OperationView(status: .accepted, eventsPosted: 0)
        #expect(try await harness.status(StatusArguments(operation: query)).operation == .found(accepted))
        let handles = EffectHandles(arguments: raw)
        let unencodable = await harness.dispatcher.refusal(
            .unencodableResult, tool: .pointer, handles: handles, caller: ToolFixture.caller)
        #expect(unencodable.code == .internalError)
        #expect(unencodable.operation == nil)
        let noNode = await harness.dispatcher.effect(
            .pointer(try PointerArguments(arguments: raw)), received: raw,
            caller: ToolCaller(principal: ToolFixture.caller.principal, nodeAddress: nil))
        #expect(noNode.code == .internalError)
        #expect(noNode.toolError?.operation == nil)

        proceed.open()
        guard case .completed = try await admitting.value else {
            Issue.record("the admitted call did not complete")
            return
        }
        let after = await harness.dispatcher.refusal(
            .unencodableResult, tool: .pointer, handles: handles, caller: ToolFixture.caller)
        #expect(after.operationView?.status == .completed)
    }
}
