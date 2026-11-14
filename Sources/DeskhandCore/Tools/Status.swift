public enum LeaseOperation: String, CaseIterable, Sendable {
    case acquire, renew, release
}

/// The optional `lease` argument of `status` (contract 5.1).
public struct LeaseRequest: Hashable, Sendable {
    public let operation: LeaseOperation
    public let holderID: HolderID
    /// Validated for every operation, used only by `acquire` and `renew`. Defaults to 30,000.
    public let ttlMs: Int
}

public struct StatusArguments: Hashable, Sendable {
    public let lease: LeaseRequest?

    public init(arguments: JSONObject) throws(ArgumentError) {
        let reader = try ObjectReader(.object(arguments), at: .root, allowing: ["lease"])
        lease = try reader.optional("lease") { value, path throws(ArgumentError) in
            let lease = try ObjectReader(value, at: path, allowing: ["op", "holder_id", "ttl_ms"])
            return LeaseRequest(
                operation: try lease.required("op", Decode.oneOf(LeaseOperation.self)),
                holderID: try lease.required("holder_id", Decode.identifier(HolderID.self)),
                ttlMs: try lease.optional("ttl_ms", Decode.integer(ContractConstants.leaseTTLMsRange))
                    ?? ContractConstants.defaultLeaseTTLMs
            )
        }
    }
}

/// Why a lease operation was refused. Reported in `lease_result.code`, never as a tool error.
public enum LeaseRefusal: String, CaseIterable, Sendable {
    case gated, paused, disarmed
    case leaseNotHeld = "lease_not_held"
    case leaseHeldByOther = "lease_held_by_other"
    case leaseExpired = "lease_expired"
}

public enum LeaseOutcome: Hashable, Sendable {
    case acquired, renewed, released, notHeld
    case refused(LeaseRefusal)
}

/// `status.lease_result`: present exactly when the call carried a `lease` argument.
public struct LeaseResult: Hashable, Sendable, JSONRepresentable {
    public var operation: LeaseOperation
    public var outcome: LeaseOutcome

    public init(operation: LeaseOperation, outcome: LeaseOutcome) {
        self.operation = operation
        self.outcome = outcome
    }

    public var jsonValue: JSONValue {
        let outcomeName: String
        var object: JSONObject = ["op": .string(operation.rawValue)]
        switch outcome {
        case .acquired: outcomeName = "acquired"
        case .renewed: outcomeName = "renewed"
        case .released: outcomeName = "released"
        case .notHeld: outcomeName = "not_held"
        case .refused(let refusal):
            outcomeName = "refused"
            object["code"] = .string(refusal.rawValue)
        }
        object["outcome"] = .string(outcomeName)
        return .object(object)
    }
}

/// `status.lease`: the live lease as the caller may see it (contract 5.4).
public struct LeaseView: Hashable, Sendable, JSONRepresentable {
    /// `nil` when the lease is held under a different principal.
    public var holderID: HolderID?
    public var acquiredAt: Timestamp
    public var expiresAt: Timestamp
    public var expiresInMs: Int

    public init(holderID: HolderID?, acquiredAt: Timestamp, expiresAt: Timestamp, expiresInMs: Int) {
        self.holderID = holderID
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.expiresInMs = expiresInMs
    }

    public var jsonValue: JSONValue {
        [
            "holder_id": holderID.map { .string($0.rawValue) } ?? .null, "acquired_at": acquiredAt.jsonValue,
            "expires_at": expiresAt.jsonValue, "expires_in_ms": JSONValue(expiresInMs),
        ]
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
    public var lease: LeaseView?
    public var leaseResult: LeaseResult?
    public var displayConfigGeneration: DisplayConfigGeneration
    public var limits: Limits

    public init(
        serverVersion: String, mac: String, time: Timestamp, startedAt: Timestamp, activeStates: ActiveStates,
        conditions: Set<Condition>, armedUntil: Timestamp?, lease: LeaseView?, leaseResult: LeaseResult?,
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
        self.leaseResult = leaseResult
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
        object["lease_result"] = leaseResult?.jsonValue
        return .object(object)
    }
}
