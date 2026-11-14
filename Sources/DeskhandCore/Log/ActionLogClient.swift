/// A connection to the action log's writer. A conformer only moves lines; the intent-before,
/// outcome-after protocol is ``commitIntent(_:)`` and ``commitOutcome(_:_:measured:now:)``, which
/// conformers cannot replace, and which alone can produce the ``IntentReceipt`` that admission
/// (``OperationStore/admit(_:digest:now:)``) and so every posted effect needs.
public protocol ActionLogClient: Sendable {
    /// Returns only once the writer has durably committed `line`. Throws when it cannot say so: the
    /// line may then be in the log or not, and the caller treats it as not committed.
    func append(_ line: ActionLogLine) async throws(ActionLogFailure)
}

extension ActionLogClient {
    /// Commits the intent entry (contract 12.3, step 2). The receipt is the only way to obtain an
    /// ``IntentReceipt``, so an effect whose intent was not committed has nothing to post with. On a
    /// throw the call is refused with ``ActionLogFailure/toolError(measured:state:operationID:)``.
    ///
    /// The executor waits for it only so long, and a line it stopped waiting for may still be
    /// committed afterwards. The call's `log_unavailable` refusal entry is therefore written only
    /// once this returns, so it follows such an intent in the log instead of preceding it.
    public func commitIntent(_ intent: ActionLogIntent) async throws(ActionLogFailure) -> IntentReceipt {
        try await append(ActionLogLine(.intent(intent)))
        return IntentReceipt(intent: intent)
    }

    /// Writes the outcome entry once the final record is durable (contract 12.3, step 8). A throw
    /// does not change the call's result: the input is already out (contract 11.3).
    ///
    /// `measured` is the result's, ``OperationOutcome/measured`` for an outcome the store recorded;
    /// the entry takes its frontmost and target apps from it (contract 12.10), never a window
    /// title. `nil` only for a clean stop with nothing measured.
    public func commitOutcome(
        _ receipt: IntentReceipt, _ outcome: ActionOutcome, measured: Measured?, now: Timestamp
    ) async throws(ActionLogFailure) {
        let entry = ActionLogOutcome(receipt: receipt, outcome: outcome, measured: measured, time: now)
        try await append(ActionLogLine(.outcome(entry)))
    }

    /// Writes the refusal entry of an effect call refused before admission (contract 12.10). Best
    /// effort: a throw changes nothing for the call, which posted nothing. The caller only notes the
    /// failure for the `log_unavailable` condition.
    public func commitRefusal(_ refusal: ActionLogRefusal) async throws(ActionLogFailure) {
        try await append(ActionLogLine(.refusal(refusal)))
    }
}

/// Proof that an intent entry was committed. It has only the synthesized internal initializer, so
/// outside this module only ``ActionLogClient/commitIntent(_:)`` makes one, after the writer
/// acknowledged the line. ``OperationStore/admit(_:digest:now:)`` takes one, so no operation is
/// admitted, and nothing posted, without a committed intent (contract 12.3 steps 2 and 3).
public struct IntentReceipt: Hashable, Sendable {
    public let intent: ActionLogIntent
}

/// Why the writer did not acknowledge a line (contract 11.3). Each sets the `log_unavailable`
/// condition; on an intent entry it also refuses the call.
public enum ActionLogFailure: Error, Hashable, Sendable {
    case connectionRefused
    case connectionLost
    /// The writer answered but did not commit the entry.
    case notCommitted

    /// The refusal for an effect call whose intent entry failed (contract 9.5, step 15). No record
    /// exists yet, so it carries no `operation`.
    public func toolError(measured: Measured, state: DeskhandState, operationID: OperationID) -> ToolError {
        ToolError(
            .logUnavailable(measured: measured),
            message: "The action log could not record the intent, so nothing was posted.", state: state,
            operationID: operationID)
    }
}
