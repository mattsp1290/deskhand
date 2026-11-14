/// The key of an operation record (contract 4.3, 12.1). A handle under another principal or
/// another `holder_id` is a different record.
public struct OperationKey: Hashable, Sendable, CustomStringConvertible {
    public let principal: Principal
    public let holderID: HolderID
    public let operationID: OperationID

    public init(principal: Principal, holderID: HolderID, operationID: OperationID) {
        self.principal = principal
        self.holderID = holderID
        self.operationID = operationID
    }

    public var description: String { "(\(principal), \(holderID), \(operationID))" }
}

/// How an operation that ran to its own end finished, with the `structuredContent` returned for it
/// (contract 12.5). A repeat is answered from these stored bytes, never re-derived.
public enum OperationEnding: Hashable, Sendable {
    case completed(result: JSONObject)
    case aborted(error: JSONObject)
    case failed(error: JSONObject)

    public var status: OperationStatus {
        switch self {
        case .completed: .completed
        case .aborted: .aborted
        case .failed: .failed
        }
    }

    public var structuredContent: JSONObject {
        switch self {
        case .completed(let content), .aborted(let content), .failed(let content): content
        }
    }

    init?(status: OperationStatus, structuredContent: JSONObject) {
        switch status {
        case .completed: self = .completed(result: structuredContent)
        case .aborted: self = .aborted(error: structuredContent)
        case .failed: self = .failed(error: structuredContent)
        case .accepted, .executing, .failedBeforeExecution, .abortedByRestart: return nil
        }
    }
}

/// Where a record is in its lifecycle (contract 12.2):
/// `accepted -> executing -> completed | aborted | failed`, and on a restart `accepted ->
/// failed_before_execution`, `executing -> aborted_by_restart`. Only `accepted` and `executing`
/// change; every other phase is final and never rewritten.
public enum OperationPhase: Hashable, Sendable {
    /// Admitted; nothing has been posted.
    case accepted
    /// Posting events. `eventsPosted` is the last count the executor reported.
    case executing(eventsPosted: Int)
    case ended(OperationEnding, eventsPosted: Int)
    case failedBeforeExecution
    /// `eventsPosted` is the last count that reached the disk, so a lower bound.
    case abortedByRestart(eventsPosted: Int)

    public var status: OperationStatus {
        switch self {
        case .accepted: .accepted
        case .executing: .executing
        case .ended(let ending, _): ending.status
        case .failedBeforeExecution: .failedBeforeExecution
        case .abortedByRestart: .abortedByRestart
        }
    }

    public var eventsPosted: Int {
        switch self {
        case .accepted, .failedBeforeExecution: 0
        case .executing(let count), .ended(_, let count), .abortedByRestart(let count): count
        }
    }

    public var isFinal: Bool { status.isTerminal }

    /// The only place a phase changes, live and when the journal is replayed, so a transition the
    /// contract does not allow is refused the same way in both. Counts never go down.
    func applying(_ transition: OperationTransition) -> OperationPhase? {
        switch (self, transition) {
        case (.accepted, .execute):
            return .executing(eventsPosted: 0)
        case (.accepted, .finish(let ending, 0)) where ending.status != .completed:
            // A record write that fails before the first event ends the operation as `failed`
            // (contract 12.3); nothing was posted, so it never was `executing`.
            return .ended(ending, eventsPosted: 0)
        case (.accepted, .interrupt(0)), (.accepted, .restart):
            return .failedBeforeExecution
        case (.executing(let posted), .progress(let count)) where count >= posted:
            return .executing(eventsPosted: count)
        case (.executing(let posted), .finish(let ending, let count)) where count >= posted:
            return .ended(ending, eventsPosted: count)
        case (.executing(let posted), .interrupt(let count)) where count >= posted:
            return .abortedByRestart(eventsPosted: count)
        case (.executing(let posted), .restart):
            return .abortedByRestart(eventsPosted: posted)
        default:
            return nil
        }
    }
}

/// A change to one record. ``OperationPhase/applying(_:)`` decides which are legal.
enum OperationTransition: Hashable, Sendable {
    case execute
    case progress(eventsPosted: Int)
    case finish(OperationEnding, eventsPosted: Int)
    /// A clean stop (contract 15.2): the count is exact.
    case interrupt(eventsPosted: Int)
    /// Recovery at start (contract 12.9). Never journaled: the rewritten file carries its result.
    case restart
}

/// One admitted call (contract 12.1): its status, `events_posted`, the request digest, the time of
/// admission and, once it is over, the result that was returned.
public struct OperationRecord: Hashable, Sendable {
    public let key: OperationKey
    public let digest: RequestDigest
    /// The retention window runs from here (contract 12.6).
    public let admittedAt: Timestamp
    public internal(set) var phase: OperationPhase

    public var view: OperationView { OperationView(status: phase.status, eventsPosted: phase.eventsPosted) }
}

/// Proof that a call was admitted, naming the record its executor advances. Only
/// ``OperationStore/admit(_:digest:now:)`` makes one.
public struct OperationTicket: Hashable, Sendable {
    public let key: OperationKey
    public let admittedAt: Timestamp
}

/// How an executed operation ended, as the executor reports it to ``OperationStore``. Every
/// outcome carries `measured`, because the result of every admitted call does (contract 6.7): a
/// success inside its result, an error beside it.
public enum OperationOutcome: Hashable, Sendable {
    case completed(EffectResult)
    /// Stopped early for a cause in contract 12.4: a state's name, `user_active`, `denied_app`,
    /// `stale_frame`, `lease_expired`, `lease_not_held` or `cancelled`.
    ///
    /// `measured` is what the last look took, also when the last look itself failed; an operation
    /// that ended before it reports the check before admission. A `denied_app` keeps the facts its
    /// reason carries, from the check that failed.
    case aborted(ToolError, measured: Measured)
    /// A fault inside deskhand: `internal_error`. `measured` as for ``aborted(_:measured:)``.
    case failed(ToolError, measured: Measured)

    public var status: OperationStatus {
        switch self {
        case .completed: .completed
        case .aborted: .aborted
        case .failed: .failed
        }
    }

    public var isError: Bool { status != .completed }

    /// The `measured` member of the result, which is also where the outcome entry of the action log
    /// takes its apps from.
    public var measured: Measured {
        switch self {
        case .completed(let result): result.measured
        case .aborted(let error, let measured), .failed(let error, let measured): error.reason.measured ?? measured
        }
    }

    public var structuredContent: JSONValue {
        switch self {
        case .completed(let result): result.jsonValue
        case .aborted(let error, _), .failed(let error, _): error.jsonValue
        }
    }

    /// The outcome as it is returned the first time: `operation_id`, the count, `replayed: false`
    /// and, on an error, `measured` come from the record and the outcome, so what is stored and
    /// what is sent cannot disagree with them.
    func stamped(for key: OperationKey, eventsPosted: Int) -> OperationOutcome {
        switch self {
        case .completed(var result):
            result.operationID = key.operationID
            result.eventsPosted = eventsPosted
            result.replayed = false
            return .completed(result)
        case .aborted(let error, let measured):
            let view = OperationView(status: .aborted, eventsPosted: eventsPosted)
            return .aborted(error.recording(key, view, measured), measured: measured)
        case .failed(let error, let measured):
            let view = OperationView(status: .failed, eventsPosted: eventsPosted)
            return .failed(error.recording(key, view, measured), measured: measured)
        }
    }

    var ending: OperationEnding {
        let content = structuredContent.objectValue ?? [:]
        return OperationEnding(status: status, structuredContent: content)!
    }
}

extension ToolError {
    fileprivate func recording(_ key: OperationKey, _ view: OperationView, _ measured: Measured) -> ToolError {
        ToolError(
            reason, message: message, state: state, operationID: key.operationID, operation: .result(view),
            measured: measured)
    }
}

/// The answer to a same-digest repeat of a final record (contract 4.3, 12.5). It posts nothing,
/// and is only sent while the state is `ok` (Appendix A item 21).
public struct OperationReplay: Hashable, Sendable {
    /// What the repeat is answered from.
    public enum Answer: Hashable, Sendable {
        /// The `structuredContent` stored when the operation ended.
        case stored(OperationEnding)
        /// A restart ended the operation, so nothing was stored (contract 12.9): the repeat gets
        /// `interrupted` with the record's status, `failed_before_execution` or `aborted_by_restart`,
        /// and its count.
        case interrupted(OperationView)
    }

    /// Always final.
    public let record: OperationRecord
    public let answer: Answer

    /// `nil` for a record that is still `accepted` or `executing`: a repeat of it is
    /// `operation_in_progress`, never a replay.
    init?(_ record: OperationRecord) {
        switch record.phase {
        case .ended(let ending, _): answer = .stored(ending)
        case .failedBeforeExecution, .abortedByRestart: answer = .interrupted(record.view)
        case .accepted, .executing: return nil
        }
        self.record = record
    }

    /// Every replay but that of a `completed` record is an `isError` result.
    public var isError: Bool { record.phase.status != .completed }

    /// What the repeat returns, given the state as the response is produced (contract 12.5).
    ///
    /// - A stored success comes back as it was stored, with `replayed: true` and nothing else
    ///   changed.
    /// - A stored error also keeps its `code`, `state`, `operation`, `measured` and `details`. It
    ///   gains `replayed: true` and `current_state`, so a replayed `secure_input` abort still says
    ///   `secure_input`, and the state now is beside it.
    /// - `interrupted` has no stored result. It is built now, so its `state` and its
    ///   `current_state` are both `currentState`.
    public func structuredContent(currentState: DeskhandState) -> JSONValue {
        switch answer {
        case .stored(.completed(var result)):
            result["replayed"] = true
            return .object(result)
        case .stored(.aborted(var error)), .stored(.failed(var error)):
            error["replayed"] = true
            error["current_state"] = .string(currentState.rawValue)
            return .object(error)
        case .interrupted(let view):
            let message =
                view.status == .failedBeforeExecution
                ? "deskhand stopped before this operation started. No input was posted."
                : "deskhand stopped while this operation was executing. Input may have been posted."
            return ToolError(
                .interrupted, message: message, state: currentState, operationID: record.key.operationID,
                operation: .replayed(view, currentState: currentState)
            ).jsonValue
        }
    }
}

/// What a call whose `operation_id` already has a record gets (the table in contract 4.3).
public enum OperationLookup: Hashable, Sendable {
    /// No record inside the retention window: the call is judged afresh.
    case absent
    /// The record's digest differs: `operation_id_conflict`, and the call never executes.
    case conflict(OperationView)
    /// Same digest, still `accepted` or `executing`: `operation_in_progress` at once.
    case inProgress(OperationView)
    /// Same digest, final.
    case replay(OperationReplay)

    init(_ record: OperationRecord?, digest: RequestDigest) {
        guard let record else {
            self = .absent
            return
        }
        if record.digest != digest {
            self = .conflict(record.view)
        } else if let replay = OperationReplay(record) {
            self = .replay(replay)
        } else {
            self = .inProgress(record.view)
        }
    }
}

/// The result of ``OperationStore/admit(_:digest:now:)``.
public enum OperationAdmission: Hashable, Sendable {
    /// A record was created as `accepted`: the call is admitted.
    case new(OperationTicket)
    case conflict(OperationView)
    case inProgress(OperationView)
    case replay(OperationReplay)
    /// The principal has `operation_max_records` records inside the window: `operation_capacity`.
    case capacity
}
