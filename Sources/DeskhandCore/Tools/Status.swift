/// `status.operation` as an argument: the record to look up (contract 6.1). Both members are required.
public struct OperationQuery: Hashable, Sendable {
    public let holderID: HolderID
    public let operationID: OperationID

    public init(holderID: HolderID, operationID: OperationID) {
        self.holderID = holderID
        self.operationID = operationID
    }

    /// The record key under the caller's principal: a lookup never sees another principal's records.
    public func key(for principal: Principal) -> OperationKey {
        OperationKey(principal: principal, holderID: holderID, operationID: operationID)
    }
}

/// The arguments of `status`, a pure read (contract 6.1). Both are optional.
public struct StatusArguments: Hashable, Sendable {
    /// Report the lease as seen from this holder. `nil`: `status.lease` is `null`.
    public let holderID: HolderID?
    /// Look up this operation record. `nil`: `status.operation` is absent.
    public let operation: OperationQuery?

    public init(holderID: HolderID? = nil, operation: OperationQuery? = nil) {
        self.holderID = holderID
        self.operation = operation
    }

    public init(arguments: JSONObject) throws(ArgumentError) {
        let reader = try ObjectReader(.object(arguments), at: .root, allowing: ["holder_id", "operation"])
        holderID = try reader.optional("holder_id", Decode.identifier(HolderID.self))
        operation = try reader.optional("operation") { value, path throws(ArgumentError) in
            let query = try ObjectReader(value, at: path, allowing: ["holder_id", "operation_id"])
            return OperationQuery(
                holderID: try query.required("holder_id", Decode.identifier(HolderID.self)),
                operationID: try query.required("operation_id", Decode.identifier(OperationID.self)))
        }
    }
}

/// `status.operation` in a result: the record's status and count, never its stored result.
public enum StatusOperation: Hashable, Sendable, JSONRepresentable {
    /// No record, and no call with that key being admitted: no input was ever posted for it, or its
    /// record has passed the retention window.
    case notFound
    /// A call that is being admitted is reported as `accepted` with 0 events.
    case found(OperationView)

    public var jsonValue: JSONValue {
        switch self {
        case .notFound: .null
        case .found(let view): view.jsonValue
        }
    }
}

/// `status.limits`: the contract constants plus the values configured on this Mac.
public struct Limits: Hashable, Sendable, JSONRepresentable {
    public var frameMaxAgeMs: Int
    public var actionsPerMinute: Int
    public var operationRetentionMs: Int
    public var operationMaxRecords: Int

    public init(
        frameMaxAgeMs: Int = ContractConstants.defaultFrameMaxAgeMs,
        actionsPerMinute: Int = ContractConstants.defaultActionsPerMinute,
        operationRetentionMs: Int = ContractConstants.defaultOperationRetentionMs,
        operationMaxRecords: Int = ContractConstants.defaultOperationMaxRecords
    ) {
        self.frameMaxAgeMs = frameMaxAgeMs
        self.actionsPerMinute = actionsPerMinute
        self.operationRetentionMs = operationRetentionMs
        self.operationMaxRecords = operationMaxRecords
    }

    public var jsonValue: JSONValue {
        typealias C = ContractConstants
        return [
            "max_long_edge": JSONValue(C.maxLongEdge), "min_long_edge": JSONValue(C.minLongEdge),
            "max_pixels": JSONValue(C.maxPixels), "max_image_bytes": JSONValue(C.maxImageBytes),
            "frame_max_age_ms": JSONValue(frameMaxAgeMs),
            "user_activity_lookback_ms": JSONValue(C.userActivityLookbackMs),
            "actions_per_minute": JSONValue(actionsPerMinute),
            "lease_ttl_min_ms": JSONValue(C.leaseTTLMsRange.lowerBound),
            "lease_ttl_max_ms": JSONValue(C.leaseTTLMsRange.upperBound),
            "keyboard_max_text_length": JSONValue(C.keyboardMaxTextLength),
            "operation_retention_ms": JSONValue(operationRetentionMs),
            "operation_max_records": JSONValue(operationMaxRecords),
        ]
    }
}

/// `structuredContent` of a successful `status` call (contract 6.1).
public struct StatusResult: Hashable, Sendable, JSONRepresentable {
    public var serverVersion: String
    public var mac: String
    public var time: Timestamp
    public var startedAt: Timestamp
    /// `state` and `active_states` are both derived from this.
    public var activeStates: ActiveStates
    public var conditions: Set<Condition>
    public var armedUntil: Timestamp?
    /// `nil` exactly when the call named no `holder_id`.
    public var lease: LeaseView?
    /// `nil` exactly when the call had no `operation` argument; the member is then absent.
    public var operation: StatusOperation?
    public var displayConfigGeneration: DisplayConfigGeneration
    public var limits: Limits

    public init(
        serverVersion: String, mac: String, time: Timestamp, startedAt: Timestamp, activeStates: ActiveStates,
        conditions: Set<Condition>, armedUntil: Timestamp?, lease: LeaseView?, operation: StatusOperation?,
        displayConfigGeneration: DisplayConfigGeneration, limits: Limits
    ) {
        self.serverVersion = serverVersion
        self.mac = mac
        self.time = time
        self.startedAt = startedAt
        self.activeStates = activeStates
        self.conditions = conditions
        self.armedUntil = armedUntil
        self.lease = lease
        self.operation = operation
        self.displayConfigGeneration = displayConfigGeneration
        self.limits = limits
    }

    public var jsonValue: JSONValue {
        var object: JSONObject = [
            "contract_version": .string(ContractConstants.contractVersion),
            "mcp_protocol_version": .string(ContractConstants.mcpProtocolVersion),
            "server_version": .string(serverVersion), "mac": .string(mac), "time": time.jsonValue,
            "started_at": startedAt.jsonValue, "state": .string(activeStates.current.rawValue),
            "active_states": .array(activeStates.inPrecedenceOrder.map { .string($0.rawValue) }),
            "conditions": .array(Condition.allCases.filter(conditions.contains).map { .string($0.rawValue) }),
            "armed_until": armedUntil?.jsonValue ?? .null, "lease": lease?.jsonValue ?? .null,
            "display_config_generation": JSONValue(displayConfigGeneration.rawValue), "limits": limits.jsonValue,
        ]
        object["operation"] = operation?.jsonValue
        return .object(object)
    }
}
