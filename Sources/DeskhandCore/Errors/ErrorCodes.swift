/// Every code an `isError` tool result can carry in `structuredContent.code` (contract 9.3). The
/// first nine are the blocking states' names.
public enum ToolErrorCode: String, CaseIterable, Sendable {
    case gated, paused, disarmed
    case notConsole = "not_console"
    case locked
    case displayAsleep = "display_asleep"
    case permissionMissing = "permission_missing"
    case permissionStale = "permission_stale"
    case secureInput = "secure_input"
    case staleFrame = "stale_frame"
    case outOfFrame = "out_of_frame"
    case userActive = "user_active"
    case deniedApp = "denied_app"
    case deniedShortcut = "denied_shortcut"
    case rateLimited = "rate_limited"
    case busy
    case leaseNotHeld = "lease_not_held"
    case leaseHeldByOther = "lease_held_by_other"
    case leaseExpired = "lease_expired"
    case invalidArgument = "invalid_argument"
    case imageTooLarge = "image_too_large"
    case operationInProgress = "operation_in_progress"
    case operationIDConflict = "operation_id_conflict"
    case operationCapacity = "operation_capacity"
    case logUnavailable = "log_unavailable"
    case cleanupPending = "cleanup_pending"
    case cancelled, interrupted
    case internalError = "internal_error"
}

/// The numeric codes of JSON-RPC errors (contract 9.4): the request never reached a tool.
public enum JSONRPCErrorCode: Int, CaseIterable, Sendable {
    case parseError = -32_700
    case invalidRequest = -32_600
    case methodNotFound = -32_601
    case invalidParams = -32_602
    case internalError = -32_603
    case headerMismatch = -32_020
    case unsupportedProtocolVersion = -32_022

    public var defaultMessage: String {
        switch self {
        case .parseError: "Parse error"
        case .invalidRequest: "Invalid Request"
        case .methodNotFound: "Method not found"
        case .invalidParams: "Invalid params"
        case .internalError: "Internal error"
        case .headerMismatch: "Header mismatch"
        case .unsupportedProtocolVersion: "Unsupported protocol version"
        }
    }
}

/// A JSON-RPC `error` member. A refusal from a tool is a ``ToolError`` instead, never this type.
public struct JSONRPCError: Error, Hashable, Sendable, JSONRepresentable {
    public let code: JSONRPCErrorCode
    public let message: String
    /// `{"detail": ..., "header": ...}` for diagnosis; not stable.
    public let data: JSONObject?

    public init(_ code: JSONRPCErrorCode, message: String? = nil, data: JSONObject? = nil) {
        self.code = code
        self.message = message ?? code.defaultMessage
        self.data = data
    }

    public static func unknownTool(_ name: String) -> JSONRPCError {
        JSONRPCError(.invalidParams, message: "Unknown tool: \(name)")
    }

    public var jsonValue: JSONValue {
        var error: JSONObject = ["code": JSONValue(code.rawValue), "message": .string(message)]
        error["data"] = data.map(JSONValue.object)
        return .object(error)
    }
}
