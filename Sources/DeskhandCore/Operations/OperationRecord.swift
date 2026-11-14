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

/// How an executed operation ended, as the executor reports it to ``OperationStore``.
public enum OperationOutcome: Hashable, Sendable {
    case completed(EffectResult)
    /// Stopped early for a cause in contract 12.4: a state's name, `user_active`, `denied_app`,
    /// `lease_expired`, `lease_not_held` or `cancelled`.
    case aborted(ToolError)
    /// A fault inside deskhand: `internal_error`.
    case failed(ToolError)

    public var status: OperationStatus {
        switch self {
        case .completed: .completed
        case .aborted: .aborted
        case .failed: .failed
        }
    }

    public var isError: Bool { status != .completed }

    public var structuredContent: JSONValue {
        switch self {
        case .completed(let result): result.jsonValue
        case .aborted(let error), .failed(let error): error.jsonValue
        }
    }

    /// The outcome as it is returned the first time: `operation_id`, the count and `replayed: false`
    /// come from the record, so what is stored and what is sent cannot disagree with it.
    func stamped(for key: OperationKey, eventsPosted: Int) -> OperationOutcome {
        switch self {
        case .completed(var result):
            result.operationID = key.operationID
            result.eventsPosted = eventsPosted
            result.replayed = false
            return .completed(result)
        case .aborted(let error):
            return .aborted(error.recording(key, OperationView(status: .aborted, eventsPosted: eventsPosted)))
        case .failed(let error):
            return .failed(error.recording(key, OperationView(status: .failed, eventsPosted: eventsPosted)))
        }
    }

    var ending: OperationEnding {
        let content = structuredContent.objectValue ?? [:]
        return OperationEnding(status: status, structuredContent: content)!
    }
}

extension ToolError {
    fileprivate func recording(_ key: OperationKey, _ view: OperationView) -> ToolError {
        ToolError(
            reason, message: message, state: state, operationID: key.operationID,
            operation: .result(view), measured: measured)
    }
}

/// The answer to a same-digest repeat of a finished operation (contract 4.3, 12.5). It posts
/// nothing, and is only sent while the state is `ok` (Appendix A item 21).
public struct OperationReplay: Hashable, Sendable {
    /// Always final.
    public let record: OperationRecord

    /// Every replay but that of a `completed` record is an `isError` result.
    public var isError: Bool { record.phase.status != .completed }

    /// What the repeat returns. A stored result comes back as it was stored with `replayed: true`;
    /// on a stored error `state` is the state now (Appendix A item 37). A record that a restart
    /// ended has no stored result and answers `interrupted` with its status instead.
    public func structuredContent(state: DeskhandState) -> JSONValue {
        switch record.phase {
        case .ended(.completed(var result), _):
            result["replayed"] = .bool(true)
            return .object(result)
        case .ended(.aborted(var error), _), .ended(.failed(var error), _):
            error["replayed"] = .bool(true)
            error["state"] = .string(state.rawValue)
            return .object(error)
        case .failedBeforeExecution, .abortedByRestart, .accepted, .executing:
            let message =
                record.phase.status == .failedBeforeExecution
                ? "deskhand stopped before this operation started. No input was posted."
                : "deskhand stopped while this operation was executing. Input may have been posted."
            return ToolError(
                .interrupted, message: message, state: state, operationID: record.key.operationID,
                operation: .replayed(record.view, currentState: state)
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
        } else if record.phase.isFinal {
            self = .replay(OperationReplay(record: record))
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
