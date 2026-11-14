/// The intent entry, committed as the last step before an effect call is admitted (contract 12.3,
/// step 2). Its members are identifiers, digests, an app reference and a ``LoggedAction``: there is
/// no member for typed text, image bytes, the bearer token or certificate material.
public struct ActionLogIntent: Hashable, Sendable {
    public let time: Timestamp
    public let nodeAddress: NodeAddress
    public let principal: Principal
    public let holderID: HolderID
    public let operationID: OperationID
    public let frameID: FrameID
    /// The `sha256` the frame's `screenshot` result reported: a digest of the encoded image.
    public let frameSHA256: SHA256Hex
    /// The frontmost app at the app-policy check (contract 9.5, step 14).
    public let frontmostApp: AppRef
    public let action: LoggedAction

    public var tool: ToolName { action.tool }

    public init(
        time: Timestamp, nodeAddress: NodeAddress, principal: Principal, holderID: HolderID, operationID: OperationID,
        frameID: FrameID, frameSHA256: SHA256Hex, frontmostApp: AppRef, action: LoggedAction
    ) {
        self.time = time
        self.nodeAddress = nodeAddress
        self.principal = principal
        self.holderID = holderID
        self.operationID = operationID
        self.frameID = frameID
        self.frameSHA256 = frameSHA256
        self.frontmostApp = frontmostApp
        self.action = action
    }

    public init(
        time: Timestamp, nodeAddress: NodeAddress, principal: Principal, arguments: PointerArguments,
        frameSHA256: SHA256Hex, frontmostApp: AppRef
    ) {
        self.init(
            time: time, nodeAddress: nodeAddress, principal: principal, holderID: arguments.holderID,
            operationID: arguments.operationID, frameID: arguments.frameID, frameSHA256: frameSHA256,
            frontmostApp: frontmostApp, action: .pointer(arguments.action))
    }

    public init(
        time: Timestamp, nodeAddress: NodeAddress, principal: Principal, arguments: KeyboardArguments,
        frameSHA256: SHA256Hex, frontmostApp: AppRef
    ) {
        self.init(
            time: time, nodeAddress: nodeAddress, principal: principal, holderID: arguments.holderID,
            operationID: arguments.operationID, frameID: arguments.frameID, frameSHA256: frameSHA256,
            frontmostApp: frontmostApp, action: .keyboard(LoggedKeyboardAction(arguments.action)))
    }
}

/// The outcome entry, written after the final record is durable (contract 12.3, step 7). It repeats
/// the intent's caller and handles and its time, so each outcome joins exactly one intent. It is
/// built only from an ``IntentReceipt``: an outcome without a committed intent cannot be written.
public struct ActionLogOutcome: Hashable, Sendable {
    public let time: Timestamp
    public let intentTime: Timestamp
    public let nodeAddress: NodeAddress
    public let principal: Principal
    public let holderID: HolderID
    public let operationID: OperationID
    public let tool: ToolName
    public let outcome: ActionOutcome

    init(receipt: IntentReceipt, outcome: ActionOutcome, time: Timestamp) {
        let intent = receipt.intent
        self.init(
            time: time, intentTime: intent.time, nodeAddress: intent.nodeAddress, principal: intent.principal,
            holderID: intent.holderID, operationID: intent.operationID, tool: intent.tool, outcome: outcome)
    }

    private init(
        time: Timestamp, intentTime: Timestamp, nodeAddress: NodeAddress, principal: Principal, holderID: HolderID,
        operationID: OperationID, tool: ToolName, outcome: ActionOutcome
    ) {
        self.time = time
        self.intentTime = intentTime
        self.nodeAddress = nodeAddress
        self.principal = principal
        self.holderID = holderID
        self.operationID = operationID
        self.tool = tool
        self.outcome = outcome
    }

    fileprivate static func decode(_ reader: ObjectReader) throws(ArgumentError) -> ActionLogOutcome {
        let tool = try reader.required("tool", Decode.effectTool)
        return ActionLogOutcome(
            time: try reader.required("time", Decode.timestamp),
            intentTime: try reader.required("intent_time", Decode.timestamp),
            nodeAddress: try reader.required("node_address", Decode.nodeAddress),
            principal: try reader.required("principal", Decode.principal),
            holderID: try reader.required("holder_id", Decode.identifier(HolderID.self)),
            operationID: try reader.required("operation_id", Decode.identifier(OperationID.self)), tool: tool,
            outcome: try reader.required("outcome", ActionOutcome.decode))
    }
}

/// How an admitted operation ended: its final record status (contract 12.2) and the code the call
/// returned. A `completed` operation has no code.
public enum ActionOutcome: Hashable, Sendable, JSONRepresentable {
    case completed(eventsPosted: Int)
    case aborted(AbortCause, eventsPosted: Int)
    /// A fault inside deskhand: `internal_error`.
    case failed(eventsPosted: Int)
    /// Found `accepted` after a restart: nothing was posted.
    case failedBeforeExecution
    /// Found `executing` after a restart: `eventsPosted` is a lower bound.
    case abortedByRestart(eventsPosted: Int)

    public var status: OperationStatus {
        switch self {
        case .completed: .completed
        case .aborted: .aborted
        case .failed: .failed
        case .failedBeforeExecution: .failedBeforeExecution
        case .abortedByRestart: .abortedByRestart
        }
    }

    public var code: ToolErrorCode? {
        switch self {
        case .completed: nil
        case .aborted(let cause, _): cause.code
        case .failed: .internalError
        case .failedBeforeExecution, .abortedByRestart: .interrupted
        }
    }

    public var eventsPosted: Int {
        switch self {
        case .completed(let count), .aborted(_, let count), .failed(let count), .abortedByRestart(let count): count
        case .failedBeforeExecution: 0
        }
    }

    public var jsonValue: JSONValue {
        var object: JSONObject = ["status": .string(status.rawValue), "events_posted": JSONValue(eventsPosted)]
        object["code"] = code.map { .string($0.rawValue) }
        return .object(object)
    }

    fileprivate static func decode(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> ActionOutcome {
        let reader = try ObjectReader(value, at: path, allowing: ["status", "events_posted", "code"])
        let status = try reader.required("status", Decode.oneOf(OperationStatus.self))
        let count = try reader.required("events_posted", Decode.integer(0...Decode.maxExactInteger))
        let code = try reader.optional("code", Decode.oneOf(ToolErrorCode.self))
        let outcome: ActionOutcome? =
            switch (status, code) {
            case (.completed, nil): .completed(eventsPosted: count)
            case (.aborted, let code?): AbortCause(code: code).map { .aborted($0, eventsPosted: count) }
            case (.failed, .internalError?): .failed(eventsPosted: count)
            case (.failedBeforeExecution, .interrupted?) where count == 0: .failedBeforeExecution
            case (.abortedByRestart, .interrupted?): .abortedByRestart(eventsPosted: count)
            default: nil
            }
        guard let outcome else { throw ArgumentError(at: path, "status, code and events_posted do not agree") }
        return outcome
    }
}

/// Why an executing operation was aborted (contract 12.4), as the code the call returned.
public enum AbortCause: Hashable, Sendable {
    case state(BlockingState)
    case userActive, deniedApp, leaseExpired, leaseNotHeld, cancelled

    public var code: ToolErrorCode {
        switch self {
        case .state(let state): ToolErrorCode(rawValue: state.rawValue)!
        case .userActive: .userActive
        case .deniedApp: .deniedApp
        case .leaseExpired: .leaseExpired
        case .leaseNotHeld: .leaseNotHeld
        case .cancelled: .cancelled
        }
    }

    init?(code: ToolErrorCode) {
        switch code {
        case .userActive: self = .userActive
        case .deniedApp: self = .deniedApp
        case .leaseExpired: self = .leaseExpired
        case .leaseNotHeld: self = .leaseNotHeld
        case .cancelled: self = .cancelled
        default:
            guard let state = BlockingState(rawValue: code.rawValue) else { return nil }
            self = .state(state)
        }
    }
}

public enum ActionLogEntryKind: String, CaseIterable, Hashable, Sendable {
    case intent, outcome
}

/// One line of the action log.
public enum ActionLogEntry: Hashable, Sendable, JSONRepresentable {
    case intent(ActionLogIntent)
    case outcome(ActionLogOutcome)

    /// Written into every entry as `schema_version`. A reader refuses any other value.
    public static let schemaVersion = 1

    public var kind: ActionLogEntryKind {
        switch self {
        case .intent: .intent
        case .outcome: .outcome
        }
    }

    public var jsonValue: JSONValue {
        var object: JSONObject = ["schema_version": JSONValue(Self.schemaVersion), "kind": .string(kind.rawValue)]
        switch self {
        case .intent(let intent):
            object.merge(Self.handles(intent.nodeAddress, intent.principal, intent.holderID, intent.operationID)) {
                $1
            }
            object["time"] = intent.time.jsonValue
            object["tool"] = .string(intent.tool.rawValue)
            object["frame_id"] = .string(intent.frameID.rawValue)
            object["frame_sha256"] = .string(intent.frameSHA256.description)
            object["frontmost_app"] = intent.frontmostApp.jsonValue
            object["action"] = intent.action.jsonValue
        case .outcome(let outcome):
            object.merge(Self.handles(outcome.nodeAddress, outcome.principal, outcome.holderID, outcome.operationID)) {
                $1
            }
            object["time"] = outcome.time.jsonValue
            object["intent_time"] = outcome.intentTime.jsonValue
            object["tool"] = .string(outcome.tool.rawValue)
            object["outcome"] = outcome.outcome.jsonValue
        }
        return .object(object)
    }

    private static func handles(
        _ address: NodeAddress, _ principal: Principal, _ holder: HolderID, _ operation: OperationID
    ) -> JSONObject {
        [
            "node_address": .string(address.description), "principal": .string(principal.certificateSubject),
            "holder_id": .string(holder.rawValue), "operation_id": .string(operation.rawValue),
        ]
    }

    static func decode(_ value: JSONValue) throws(ArgumentError) -> ActionLogEntry {
        let common: Set = ["schema_version", "kind", "time", "node_address", "principal", "holder_id", "operation_id"]
        guard case .object(let members) = value else { throw ArgumentError(at: .root, "must be an object") }
        _ = try Decode.integer(schemaVersion...schemaVersion)(
            members["schema_version"] ?? .null, JSONPointer.root.appending("schema_version"))
        let kind = try Decode.oneOf(ActionLogEntryKind.self)(
            members["kind"] ?? .null, JSONPointer.root.appending("kind"))
        let specific: Set<String> =
            switch kind {
            case .intent: ["tool", "frame_id", "frame_sha256", "frontmost_app", "action"]
            case .outcome: ["intent_time", "tool", "outcome"]
            }
        let reader = try ObjectReader(value, at: .root, allowing: common.union(specific))
        switch kind {
        case .intent:
            let tool = try reader.required("tool", Decode.effectTool)
            return .intent(
                ActionLogIntent(
                    time: try reader.required("time", Decode.timestamp),
                    nodeAddress: try reader.required("node_address", Decode.nodeAddress),
                    principal: try reader.required("principal", Decode.principal),
                    holderID: try reader.required("holder_id", Decode.identifier(HolderID.self)),
                    operationID: try reader.required("operation_id", Decode.identifier(OperationID.self)),
                    frameID: try reader.required("frame_id", Decode.identifier(FrameID.self)),
                    frameSHA256: try reader.required("frame_sha256", Decode.sha256),
                    frontmostApp: try reader.required("frontmost_app", Decode.appRef),
                    action: try reader.required("action", LoggedAction.decode(tool: tool))))
        case .outcome:
            return .outcome(try ActionLogOutcome.decode(reader))
        }
    }
}

/// One entry as it goes to the writer: its RFC 8785 canonical JSON followed by a single line feed.
/// Canonical JSON escapes every control character, so the only line feed is the last byte, and the
/// writer can check a line by decoding it and comparing the bytes it would write itself.
public struct ActionLogLine: Hashable, Sendable {
    public let entry: ActionLogEntry
    public let bytes: [UInt8]

    public init(_ entry: ActionLogEntry) {
        self.entry = entry
        // Every number in an entry is an integer, so canonicalization cannot meet a non-finite value.
        bytes = try! entry.jsonValue.canonicalBytes() + [UInt8(ascii: "\n")]
    }

    /// Accepts only bytes that ``init(_:)`` would produce for the entry they decode to.
    public init(verifying bytes: some Collection<UInt8>) throws(ActionLogLineError) {
        let bytes = Array(bytes)
        guard bytes.last == UInt8(ascii: "\n") else { throw .missingLineFeed }
        let value: JSONValue
        do {
            value = try JSONValue(parsing: bytes.dropLast())
        } catch {
            throw .notJSON(error)
        }
        let entry: ActionLogEntry
        do {
            entry = try ActionLogEntry.decode(value)
        } catch {
            throw .invalid(error)
        }
        let line = ActionLogLine(entry)
        guard line.bytes == bytes else { throw .notCanonical }
        self = line
    }
}

/// Why bytes offered as an action log line were refused.
public enum ActionLogLineError: Error, Hashable, Sendable, CustomStringConvertible {
    case missingLineFeed
    case notJSON(JSONParseError)
    /// The JSON is not an entry; the pointer names the offending member.
    case invalid(ArgumentError)
    /// A valid entry, but not spelled the one way deskhand writes it.
    case notCanonical

    public var description: String {
        switch self {
        case .missingLineFeed: "the line does not end with a line feed"
        case .notJSON(let error): "not JSON: \(error)"
        case .invalid(let error): "not an action log entry: \(error)"
        case .notCanonical: "not in canonical form"
        }
    }
}

extension Decode {
    /// The largest integer a double holds exactly.
    fileprivate static let maxExactInteger = 9_007_199_254_740_991

    fileprivate static func effectTool(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> ToolName {
        let tool = try oneOf(ToolName.self)(value, path)
        guard tool.isEffect else { throw ArgumentError(at: path, "must be pointer or keyboard") }
        return tool
    }

    fileprivate static func timestamp(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> Timestamp {
        guard let timestamp = Timestamp(logText: try string(value, path)) else {
            throw ArgumentError(at: path, "must be a UTC timestamp as deskhand writes it")
        }
        return timestamp
    }

    fileprivate static func nodeAddress(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> NodeAddress {
        guard let address = NodeAddress(try string(value, path)) else {
            throw ArgumentError(at: path, "must be an IPv4 or IPv6 address in canonical form")
        }
        return address
    }

    fileprivate static func principal(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> Principal {
        let subject = try string(value, path)
        guard !subject.isEmpty else { throw ArgumentError(at: path, "must not be empty") }
        return Principal(certificateSubject: subject)
    }

    fileprivate static func sha256(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> SHA256Hex {
        guard let digest = SHA256Hex(hex: try string(value, path)) else {
            throw ArgumentError(at: path, "must be 64 lowercase hex characters")
        }
        return digest
    }

    fileprivate static func appRef(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> AppRef {
        let reader = try ObjectReader(value, at: path, allowing: ["bundle_id", "team_id", "name"])
        let nullableString: ValueDecoder<String?> = { value, path throws(ArgumentError) in
            value == .null ? nil : try string(value, path)
        }
        return AppRef(
            bundleID: try reader.required("bundle_id", nullableString),
            teamID: try reader.required("team_id", nullableString), name: try reader.required("name", string))
    }
}

extension Timestamp {
    /// Parses the exact text ``description`` writes: `YYYY-MM-DDTHH:MM:SS` plus `.fff` when the
    /// milliseconds are not zero, then `Z`.
    fileprivate init?(logText text: String) {
        guard let instant = UTCInstant(rfc3339: text), instant.isWholeMillisecond else { return nil }
        self = instant.timestampRoundedUp
        guard description == text else { return nil }
    }
}
