/// The call inside the admission section, as an arrival compares itself with it (contract 9.5).
struct SectionClaim: Hashable, Sendable {
    let key: OperationKey
    let digest: RequestDigest
}

/// The one admission section of this Mac: one effect call at a time is being admitted or is
/// executing, from refusal step 3 to its final record write (contract 9.5, 12.3).
enum AdmissionSection: Hashable, Sendable {
    case idle
    /// Refusal steps 4 to 15 and the creation of the record.
    case admitting(SectionClaim)
    /// Recorded as executing, with the events posted so far: the record's own count is only
    /// written when the operation ends.
    case executing(SectionClaim, OperationTicket, eventsPosted: Int)

    var claim: SectionClaim? {
        switch self {
        case .idle: nil
        case .admitting(let claim), .executing(let claim, _, _): claim
        }
    }

    var isIdle: Bool { self == .idle }

    /// What a call arriving at step 3 gets while the section is held, or `nil` when it may enter. It
    /// does not wait: the same key gets `operation_in_progress` or `operation_id_conflict` by its
    /// digest, every other call `busy`, across principals and holders.
    func refusal(for key: OperationKey, digest: RequestDigest) -> ToolErrorReason? {
        guard let claim else { return nil }
        guard claim.key == key else { return .busy }
        return claim.digest == digest ? .operationInProgress : .operationIDConflict
    }
}

/// A refusal before admission, with what its error and its refusal entry carry (contract 9.2,
/// 12.10).
struct Refusal: Sendable {
    let reason: ToolErrorReason
    let message: String
    /// The record for the call's own key: only at steps 1 to 4 (contract 9.5).
    var operation: OperationView?
    var frontmostApp: AppRef?
    var frameSHA256: SHA256Hex?
    /// `log_unavailable`: the intent append, which its refusal entry must follow into the log.
    var afterIntent: PendingIntent?

    init(
        _ reason: ToolErrorReason, message: String? = nil, operation: OperationView? = nil, frontmostApp: AppRef? = nil,
        frameSHA256: SHA256Hex? = nil
    ) {
        self.reason = reason
        self.message = message ?? ExecutorMessages.message(for: reason)
        self.operation = operation
        self.frontmostApp = frontmostApp
        self.frameSHA256 = frameSHA256
    }
}

extension ToolErrorReason {
    /// The order of contract 9.5, which also orders the causes found at one check before an event
    /// (contract 12.4): a state's name first, by precedence.
    var abortRank: Int {
        switch self {
        case .blocked(let state): BlockingState.allCases.firstIndex(of: state) ?? 0
        case .leaseHeldByOther, .leaseExpired, .leaseNotHeld: 20
        case .userActive: 30
        case .staleFrame: 40
        case .deniedApp: 50
        case .cancelled: 60
        default: 70
        }
    }

    /// Of two causes found at one check, the one first in the order of contract 9.5.
    static func first(_ lhs: ToolErrorReason?, _ rhs: ToolErrorReason?) -> ToolErrorReason? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return rhs.abortRank < lhs.abortRank ? rhs : lhs
    }

    /// The state an error with this reason reports: a state's name always reports that state
    /// (contract 9.2).
    func reportedState(otherwise current: DeskhandState) -> DeskhandState {
        if case .blocked(let state) = self { return state.state }
        return current
    }
}

/// Messages for people and models. Not stable; never parsed (contract 9.2).
enum ExecutorMessages {
    static func message(for reason: ToolErrorReason) -> String {
        switch reason {
        case .blocked(let state): "deskhand is \(state.rawValue)."
        case .staleFrame(let reason): "The frame can no longer be trusted (\(reason.wireName)). Take a new screenshot."
        case .outOfFrame: "A target is outside the frame."
        case .userActive: "The person at the Mac is using the keyboard or pointer."
        case .deniedApp: "An app this call would reach is not allowed, or could not be determined."
        case .deniedShortcut(let shortcut): "\(shortcut) is a denied global shortcut."
        case .rateLimited: "The action ceiling for the last 60 seconds is reached."
        case .busy: "Another effect call is being admitted or is executing."
        case .leaseNotHeld: "The named holder does not hold the lease. Acquire it with the lease tool."
        case .leaseHeldByOther: "Another holder holds the lease."
        case .leaseExpired: "The named holder's lease ran out. Acquire it again with the lease tool."
        case .invalidArgument: "The arguments are not valid."
        case .imageTooLarge: "The encoded image is too large."
        case .logUnavailable: "The action log could not record the intent, so nothing was posted."
        case .operationInProgress: "A call with this operation_id is still being admitted or is executing."
        case .operationIDConflict: "This operation_id was used before with different arguments."
        case .operationCapacity: "The operation records inside the retention window are at the cap."
        case .cleanupPending: "Input from an earlier operation still has to be released."
        case .cancelled: "The caller closed the connection during this operation."
        case .interrupted: "deskhand restarted during this operation."
        case .internalError: "A fault inside deskhand."
        }
    }
}
