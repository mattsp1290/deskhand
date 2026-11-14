import DeskhandCore
import DeskhandTestSupport
import Testing

@Suite struct ActionLogClientTests {
    private func intent(_ operation: String = "op-1") throws -> ActionLogIntent {
        try LogSamples.intent(keyboard: LogSamples.typing("abc"), operation: operation)
    }

    @Test func intentThenOutcomeAreAppendedInOrder() async throws {
        let log = InMemoryActionLog()
        let intent = try intent()
        let receipt = try await log.commitIntent(intent)
        #expect(receipt.intent == intent)
        try await log.commitOutcome(
            receipt, .completed(eventsPosted: 6), measured: LogSamples.measured,
            now: LogSamples.time.adding(milliseconds: 9))
        let entries = await log.entries
        #expect(entries.map(\.kind) == [.intent, .outcome])
        #expect(entries.first == .intent(intent))
        guard case .outcome(let outcome) = entries.last else {
            Issue.record("expected an outcome entry")
            return
        }
        #expect(outcome.outcome == .completed(eventsPosted: 6))
        #expect(outcome.principal == intent.principal)
        #expect(outcome.holderID == intent.holderID)
        #expect(outcome.nodeAddress == intent.nodeAddress)
        #expect(outcome.intentTime == intent.time)
        #expect(outcome.time == LogSamples.time.adding(milliseconds: 9))
        #expect(outcome.frontmostApp == LogSamples.textEdit && outcome.targetApp == LogSamples.preview)
        #expect(outcome.frameID == intent.frameID && outcome.frameSHA256 == intent.frameSHA256)
        #expect(outcome.action == intent.action && outcome.tool == intent.tool)
    }

    @Test(arguments: [ActionLogFailure.connectionRefused, .connectionLost, .notCommitted])
    func refusedIntentYieldsNoReceiptAndWritesNothing(failure: ActionLogFailure) async throws {
        let base = InMemoryActionLog()
        let log = FaultInjectingActionLog(wrapping: base)
        await log.failNext(.intent, with: .reject(failure))
        var receipt: IntentReceipt?
        await #expect(throws: failure) { receipt = try await log.commitIntent(try intent()) }
        #expect(receipt == nil)
        #expect(await base.lines.isEmpty)
        #expect(await log.attempts.count == 1)
    }

    /// The writer may have the line when the acknowledgement is lost; deskhand still refuses, so the
    /// log shows an intent that nothing followed, never an effect without an intent.
    @Test func lostAcknowledgementStillRefuses() async throws {
        let base = InMemoryActionLog()
        let log = FaultInjectingActionLog(wrapping: base)
        await log.failNext(.intent, with: .lostAcknowledgement(.connectionLost))
        await #expect(throws: ActionLogFailure.connectionLost) { try await log.commitIntent(try intent()) }
        #expect(await base.entries.map(\.kind) == [.intent])
    }

    @Test func queuedFaultsRunOnceThenStandingFaultsApply() async throws {
        let base = InMemoryActionLog()
        let log = FaultInjectingActionLog(wrapping: base)
        await log.failNext(.intent, with: .reject(.notCommitted))
        await #expect(throws: ActionLogFailure.notCommitted) { try await log.commitIntent(try intent("op-1")) }
        let receipt = try await log.commitIntent(try intent("op-2"))

        await log.failEvery(.outcome, with: .reject(.connectionLost))
        for _ in 0..<2 {
            await #expect(throws: ActionLogFailure.connectionLost) {
                try await log.commitOutcome(receipt, .completed(eventsPosted: 1), measured: nil, now: LogSamples.time)
            }
        }
        #expect(await base.entries.map(\.kind) == [.intent])

        await log.failEvery(.outcome, with: nil)
        try await log.commitOutcome(receipt, .completed(eventsPosted: 1), measured: nil, now: LogSamples.time)
        #expect(await base.entries.map(\.kind) == [.intent, .outcome])
    }

    @Test func faultsAreScopedToTheirKind() async throws {
        let base = InMemoryActionLog()
        let log = FaultInjectingActionLog(wrapping: base)
        await log.failEvery(.outcome, with: .reject(.connectionLost))
        _ = try await log.commitIntent(try intent())
        #expect(await base.entries.map(\.kind) == [.intent])
    }

    @Test func inMemoryLogRefusesWhatTheWriterWouldRefuse() async throws {
        let log = InMemoryActionLog()
        let receipt = try await log.commitIntent(try intent())
        await #expect(throws: ActionLogFailure.notCommitted) {
            try await log.commitOutcome(receipt, .completed(eventsPosted: -1), measured: nil, now: LogSamples.time)
        }
        #expect(await log.entries.count == 1)
    }

    @Test func failureMapsToLogUnavailableWithoutAnOperation() throws {
        let measured = Measured(
            frontmostApp: LogSamples.textEdit, targetApp: nil, windowTitle: "Untitled", globalPoint: nil,
            measuredAt: LogSamples.time)
        let operationID = try #require(OperationID("op-1"))
        let error = ActionLogFailure.connectionLost.toolError(measured: measured, state: .ok, operationID: operationID)
        #expect(error.code == .logUnavailable)
        #expect(error.measured == measured)
        #expect(error.operation == nil)
        #expect(error.jsonValue["operation_id"] == "op-1")
        #expect(error.jsonValue["operation"] == nil)
    }
}
