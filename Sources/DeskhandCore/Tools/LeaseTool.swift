/// `op` of the `lease` tool (contract 5.1).
public enum LeaseOperation: String, CaseIterable, Sendable {
    case acquire, renew, release
}

/// What a `lease` call asks for. `ttl_ms` belongs to `acquire` and `renew` only, with the default
/// applied; a `release` cannot carry one.
public enum LeaseCommand: Hashable, Sendable {
    case acquire(ttlMs: Int)
    case renew(ttlMs: Int)
    case release

    public var operation: LeaseOperation {
        switch self {
        case .acquire: .acquire
        case .renew: .renew
        case .release: .release
        }
    }
}

/// The arguments of the `lease` tool (contract 5.1).
public struct LeaseArguments: Hashable, Sendable {
    public let holderID: HolderID
    public let command: LeaseCommand

    public var operation: LeaseOperation { command.operation }

    public init(holderID: HolderID, command: LeaseCommand) {
        self.holderID = holderID
        self.command = command
    }

    public init(arguments: JSONObject) throws(ArgumentError) {
        let reader = try ObjectReader(.object(arguments), at: .root, allowing: ["op", "holder_id", "ttl_ms"])
        let operation = try reader.required("op", Decode.oneOf(LeaseOperation.self))
        holderID = try reader.required("holder_id", Decode.identifier(HolderID.self))
        // The input schema is flat and cannot say that `ttl_ms` is absent on `release`, so it is
        // checked here, before its value (contract 5.1).
        if operation == .release, reader.members["ttl_ms"] != nil {
            throw ArgumentError(at: JSONPointer(["ttl_ms"]), "must be absent on release")
        }
        let ttlMs =
            try reader.optional("ttl_ms", Decode.integer(ContractConstants.leaseTTLMsRange))
            ?? ContractConstants.defaultLeaseTTLMs
        command =
            switch operation {
            case .acquire: .acquire(ttlMs: ttlMs)
            case .renew: .renew(ttlMs: ttlMs)
            case .release: .release
            }
    }
}

/// Why a lease operation was refused: `lease_result.code`, never a tool error (contract 5.1).
public enum LeaseRefusal: Hashable, Sendable {
    /// `acquire` and `renew` while `gated`, `paused` or `disarmed` holds (contract 5.2).
    case state(LeaseDroppingState)
    case leaseNotHeld
    /// How long the other holder's lease still runs if it is not renewed.
    case leaseHeldByOther(expiresInMs: Int)
    case leaseExpired

    /// The wire values of `lease_result.code`, in the schema's order.
    public enum Code: String, CaseIterable, Sendable {
        case gated, paused, disarmed
        case leaseNotHeld = "lease_not_held"
        case leaseHeldByOther = "lease_held_by_other"
        case leaseExpired = "lease_expired"
    }

    public var code: Code {
        switch self {
        case .state(let state): Code(rawValue: state.rawValue)!
        case .leaseNotHeld: .leaseNotHeld
        case .leaseHeldByOther: .leaseHeldByOther
        case .leaseExpired: .leaseExpired
        }
    }
}

public enum LeaseOutcome: Hashable, Sendable {
    case acquired, renewed, released, notHeld
    case refused(LeaseRefusal)

    var wireName: String {
        switch self {
        case .acquired: "acquired"
        case .renewed: "renewed"
        case .released: "released"
        case .notHeld: "not_held"
        case .refused: "refused"
        }
    }
}

/// `lease_result`: the operation and how it ended. `code` is present exactly when it was refused,
/// and `expires_in_ms` exactly when the code is `lease_held_by_other`.
public struct LeaseResult: Hashable, Sendable, JSONRepresentable {
    public var operation: LeaseOperation
    public var outcome: LeaseOutcome

    public init(operation: LeaseOperation, outcome: LeaseOutcome) {
        self.operation = operation
        self.outcome = outcome
    }

    public var jsonValue: JSONValue {
        var object: JSONObject = ["op": .string(operation.rawValue), "outcome": .string(outcome.wireName)]
        if case .refused(let refusal) = outcome {
            object["code"] = .string(refusal.code.rawValue)
            if case .leaseHeldByOther(let expiresInMs) = refusal { object["expires_in_ms"] = JSONValue(expiresInMs) }
        }
        return .object(object)
    }
}

/// The lease as seen from the (principal, `holder_id`) a call names (contract 5.4). It never names
/// a holder, and ``notHeldByCaller`` does not say whether the lease is free.
public enum LeaseView: Hashable, Sendable, JSONRepresentable {
    case notHeldByCaller
    case heldByCaller(acquiredAt: Timestamp, expiresAt: Timestamp, expiresInMs: Int)

    public var heldByCaller: Bool {
        if case .heldByCaller = self { return true }
        return false
    }

    public var jsonValue: JSONValue {
        switch self {
        case .notHeldByCaller: ["held_by_caller": false]
        case .heldByCaller(let acquiredAt, let expiresAt, let expiresInMs):
            [
                "held_by_caller": true, "acquired_at": acquiredAt.jsonValue, "expires_at": expiresAt.jsonValue,
                "expires_in_ms": JSONValue(expiresInMs),
            ]
        }
    }
}

/// `structuredContent` of every `lease` call that is not a tool error (contract 5.1). A refused
/// operation is one of these, with `isError: false`.
public struct LeaseToolResult: Hashable, Sendable, JSONRepresentable {
    public var result: LeaseResult
    /// The lease as the named holder sees it after the operation.
    public var lease: LeaseView

    public init(result: LeaseResult, lease: LeaseView) {
        self.result = result
        self.lease = lease
    }

    public var jsonValue: JSONValue { ["lease_result": result.jsonValue, "lease": lease.jsonValue] }
}
