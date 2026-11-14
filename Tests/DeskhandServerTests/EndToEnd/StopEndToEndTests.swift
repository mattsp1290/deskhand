import DeskhandCore
import Testing

@testable import DeskhandServer

/// A process stop in the middle of an operation (contract 15.2), as the caller sees it over the
/// wire: no response, then the truth from the record after the restart.
@Suite("end to end: clean stop", .timeLimit(.minutes(2)))
struct StopEndToEndTests {
    @Test(
        "SIGTERM mid-hold: the call's connection closes unanswered, the record is aborted_by_restart with the exact count, a repeat after the restart is interrupted"
    )
    func stopMidOperation() async throws {
        let clock = ToolClock()
        let first = try await DeskhandStack.start(.init(clock: clock))
        let arguments: JSONObject
        let report: CleanStopReport
        let stopped: StateDirectory
        do {
            let frame = try await first.ready()
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
            let host = StackStopHost()
            let stopping = Task { await first.cleanStop(host: host).stop() }
            while !(await first.executor.isStopping) { await Task.yield() }
            proceed.open()

            let answer = try await held.value
            #expect(answer.outcome.response == nil, "the stopped call was answered: \(answer.outcome)")
            report = await stopping.value
            #expect(host.steps.filter { $0 != .stopAccepting } == [.dropLease, .log, .close, .exit(0)])
            #expect(host.report == report)

            // The listener is still up: a read call is answered, an effect call is not.
            let record = try #require(try await first.lookUp("op-1"))
            #expect(record == ["status": "aborted_by_restart", "events_posted": 1])
            for call in [arguments, Wire.type("hi", frame: frame, "op-2")] {
                let later = try await first.call("keyboard", call)
                #expect(later.outcome.response == nil, "an effect call after the stop was answered: \(later.outcome)")
            }
            #expect(try await first.lookUp("op-2") == .null)
            stopped = try first.state.copy()
        } catch {
            await first.stop()
            throw error
        }
        await first.stop()

        let key = HeldInput.key(try #require(first.desk.code(for: .a)))
        let operation = OperationKey(
            principal: Principal(certificateSubject: TestPKI.expectedSubject), holderID: HolderID(Wire.holder)!,
            operationID: OperationID("op-1")!)
        #expect(
            report.executor
                == ExecutorStop(
                    operation: StoppedOperation(
                        key: operation, outcome: .abortedByRestart(eventsPosted: 1), recorded: true),
                    heldInput: []))
        #expect(report.outcomeLogged == true)
        #expect(report.leaseDropped)
        #expect(first.desk.released == [key])
        #expect(first.desk.posted.count == 1)
        guard case .outcome(let outcome)? = await first.entries.last else {
            Issue.record("no outcome entry")
            return
        }
        #expect(outcome.outcome == .abortedByRestart(eventsPosted: 1))

        clock.advance(byMilliseconds: 10_000)
        try await DeskhandStack.with(.init(state: stopped, clock: clock)) { stack in
            #expect(stack.recovery.operationRecords.restarted.isEmpty, "the clean stop left nothing to recover")
            let repeated = try await stack.call("keyboard", arguments)
            ContractShape.expectToolError(repeated, "interrupted")
            #expect(repeated.operation == ["status": "aborted_by_restart", "events_posted": 1])
            #expect(stack.desk.posted.isEmpty)
        }
    }
}
