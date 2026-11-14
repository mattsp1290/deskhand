/// Why a frame was refused, in the order the checks run (contract 8.3).
public enum StaleFrameReason: Hashable, Sendable {
    case unknown, displayChanged, notLatest, tooOld, frontmostChanged
    /// `pointIndex` names the point whose target patch changed.
    case pixelsChanged(pointIndex: Int)

    public var wireName: String {
        switch self {
        case .unknown: "unknown"
        case .displayChanged: "display_changed"
        case .notLatest: "not_latest"
        case .tooOld: "too_old"
        case .frontmostChanged: "frontmost_changed"
        case .pixelsChanged: "pixels_changed"
        }
    }
}

public enum DeniedBy: String, CaseIterable, Sendable {
    case policy
    case permittedApps = "permitted_apps"
}

/// A tool error's code together with the members that code always carries (contract 9.2), so a
/// `stale_frame` without a reason or a `denied_app` without `measured` cannot be built.
public enum ToolErrorReason: Hashable, Sendable {
    case blocked(BlockingState)
    case staleFrame(StaleFrameReason)
    case outOfFrame(pointIndex: Int, outputPixelSize: PixelSize)
    case userActive(idleMs: Int)
    /// `pointIndex` is `details.point_index`: the point of the action whose window owner caused the
    /// refusal, `nil` when the frontmost app or keyboard focus did (contract 6.9).
    case deniedApp(DeniedBy, measured: Measured, pointIndex: Int?)
    case deniedShortcut(shortcut: String)
    case rateLimited(retryAfterMs: Int)
    case leaseHeldByOther(expiresInMs: Int)
    case invalidArgument(JSONPointer)
    /// `max_image_bytes` is always ``ContractConstants/maxImageBytes``.
    case imageTooLarge(imageBytes: Int)
    case logUnavailable(measured: Measured)
    case busy, leaseNotHeld, leaseExpired, operationInProgress, operationIDConflict, operationCapacity
    case cleanupPending, cancelled, interrupted, internalError

    public var code: ToolErrorCode {
        switch self {
        case .blocked(let state): ToolErrorCode(rawValue: state.rawValue)!
        case .staleFrame: .staleFrame
        case .outOfFrame: .outOfFrame
        case .userActive: .userActive
        case .deniedApp: .deniedApp
        case .deniedShortcut: .deniedShortcut
        case .rateLimited: .rateLimited
        case .leaseHeldByOther: .leaseHeldByOther
        case .invalidArgument: .invalidArgument
        case .imageTooLarge: .imageTooLarge
        case .logUnavailable: .logUnavailable
        case .busy: .busy
        case .leaseNotHeld: .leaseNotHeld
        case .leaseExpired: .leaseExpired
        case .operationInProgress: .operationInProgress
        case .operationIDConflict: .operationIDConflict
        case .operationCapacity: .operationCapacity
        case .cleanupPending: .cleanupPending
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        case .internalError: .internalError
        }
    }

    var measured: Measured? {
        switch self {
        // A title that the policy refused is never sent, nor a drag's end past the failed check (6.7).
        case .deniedApp(_, let measured, _): measured.forDeniedApp
        case .logUnavailable(let measured): measured
        default: nil
        }
    }

    var details: JSONObject? {
        switch self {
        case .staleFrame(let reason):
            guard case .pixelsChanged(let index) = reason else { return ["reason": .string(reason.wireName)] }
            return ["reason": .string(reason.wireName), "point_index": JSONValue(index)]
        case .outOfFrame(let index, let size):
            return ["point_index": JSONValue(index), "output_pixel_size": size.jsonValue]
        case .userActive(let idle): return ["idle_ms": JSONValue(idle)]
        case .deniedApp(let deniedBy, _, let pointIndex):
            var details: JSONObject = ["denied_by": .string(deniedBy.rawValue)]
            details["point_index"] = pointIndex.map { JSONValue($0) }
            return details
        case .deniedShortcut(let shortcut): return ["shortcut": .string(shortcut)]
        case .leaseHeldByOther(let expiresIn): return ["expires_in_ms": JSONValue(expiresIn)]
        case .invalidArgument(let pointer): return ["argument": .string(pointer.description)]
        case .imageTooLarge(let bytes):
            return ["image_bytes": JSONValue(bytes), "max_image_bytes": JSONValue(ContractConstants.maxImageBytes)]
        default: return nil
        }
    }
}

/// Where an error stands relative to an operation record (contract 9.2, 9.3).
public enum OperationContext: Hashable, Sendable {
    /// A record exists for the `operation_id`, but this response is not that call's result
    /// (`operation_in_progress`, `operation_id_conflict`, or a state's name returned to a repeat).
    case existing(OperationView)
    /// This is the result of the admitted call, returned the first time: `replayed` is `false`.
    case result(OperationView)
    /// This is the result of the admitted call returned to a repeat: `replayed` is `true`, and
    /// `current_state` is the state as this response is produced, while the error's own `state` is
    /// the one stored with the result (contract 12.5).
    case replayed(OperationView, currentState: DeskhandState)
}

/// `structuredContent` of an `isError: true` tool result (`defs.json#/$defs/tool_error`). Every
/// refusal from tool dispatch onwards is one of these; protocol faults are ``JSONRPCError`` instead.
public struct ToolError: Error, Hashable, Sendable, JSONRepresentable {
    public let reason: ToolErrorReason
    /// For people and models; not stable.
    public let message: String
    /// The highest-precedence state when the error was produced. On a replay, the state stored with
    /// the result; the state now is the `currentState` of ``OperationContext/replayed(_:currentState:)``.
    /// For a state's own code it is always that state, as `defs.json` requires, whatever `state:`
    /// the initializer was given: an abort for a lease that `disarmed` dropped is `disarmed` even
    /// once `gated` holds as well.
    public let state: DeskhandState
    public let operationID: OperationID?
    public let operation: OperationContext?
    /// Facts measured for this call (contract 6.7). For `denied_app` and `log_unavailable` it is
    /// always the one carried by `reason`.
    public let measured: Measured?

    public init(
        _ reason: ToolErrorReason, message: String, state: DeskhandState, operationID: OperationID? = nil,
        operation: OperationContext? = nil, measured: Measured? = nil
    ) {
        self.reason = reason
        self.message = message
        if case .blocked(let blocked) = reason { self.state = blocked.state } else { self.state = state }
        self.operationID = operationID
        self.operation = operation
        self.measured = reason.measured ?? measured
    }

    public var code: ToolErrorCode { reason.code }

    public var jsonValue: JSONValue {
        var object: JSONObject = [
            "code": .string(code.rawValue), "message": .string(message), "state": .string(state.rawValue),
        ]
        object["operation_id"] = operationID.map { .string($0.rawValue) }
        switch operation {
        case .existing(let view): object["operation"] = view.jsonValue
        case .result(let view):
            object["operation"] = view.jsonValue
            object["replayed"] = false
        case .replayed(let view, let currentState):
            object["operation"] = view.jsonValue
            object["replayed"] = true
            object["current_state"] = .string(currentState.rawValue)
        case nil: break
        }
        if case .rateLimited(let retryAfter) = reason { object["retry_after_ms"] = JSONValue(retryAfter) }
        object["measured"] = measured?.jsonValue
        object["details"] = reason.details.map(JSONValue.object)
        return .object(object)
    }
}
