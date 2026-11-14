/// The validated arguments of an effect call.
public enum EffectCallArguments: Hashable, Sendable {
    case pointer(PointerArguments)
    case keyboard(KeyboardArguments)

    public var tool: ToolName {
        switch self {
        case .pointer: .pointer
        case .keyboard: .keyboard
        }
    }

    var holderID: HolderID {
        switch self {
        case .pointer(let arguments): arguments.holderID
        case .keyboard(let arguments): arguments.holderID
        }
    }

    var frameID: FrameID {
        switch self {
        case .pointer(let arguments): arguments.frameID
        case .keyboard(let arguments): arguments.frameID
        }
    }

    var operationID: OperationID {
        switch self {
        case .pointer(let arguments): arguments.operationID
        case .keyboard(let arguments): arguments.operationID
        }
    }

    var permittedApps: Set<BundleID>? {
        switch self {
        case .pointer(let arguments): arguments.permittedApps
        case .keyboard(let arguments): arguments.permittedApps
        }
    }

    /// What the action log records: typed text only as its length (contract 12.10).
    var loggedAction: LoggedAction {
        switch self {
        case .pointer(let arguments): .pointer(arguments.action)
        case .keyboard(let arguments): .keyboard(LoggedKeyboardAction(arguments.action))
        }
    }
}

/// One `pointer` or `keyboard` call whose arguments passed validation (refusal step 2), as the
/// executor takes it.
public struct EffectCall: Sendable {
    public let principal: Principal
    /// The source address of the connection, for the action log.
    public let nodeAddress: NodeAddress
    public let arguments: EffectCallArguments
    /// Over `{name, arguments}` as received (contract 12.1).
    public let digest: RequestDigest
    public let connection: any ConnectionLiveness

    public init(
        principal: Principal, nodeAddress: NodeAddress, arguments: EffectCallArguments, digest: RequestDigest,
        connection: any ConnectionLiveness
    ) {
        self.principal = principal
        self.nodeAddress = nodeAddress
        self.arguments = arguments
        self.digest = digest
        self.connection = connection
    }

    public var key: OperationKey {
        OperationKey(principal: principal, holderID: arguments.holderID, operationID: arguments.operationID)
    }

    var scope: FrameScope { FrameScope(principal: principal, holderID: arguments.holderID) }
}

/// What an effect call answers with: the `structuredContent` of its `tools/call` result.
public enum EffectAnswer: Sendable {
    /// The action ran to its end. `replayed` is `false`.
    case completed(EffectResult)
    /// A refusal before admission, or the abort or failure of an admitted call.
    case error(ToolError)
    /// A repeat of a final operation, answered from its record and posting nothing (contract 12.5).
    case replayed(OperationReplay, structuredContent: JSONValue)
    /// The connection closed before admission: nothing was posted, no record was kept, and nobody is
    /// left to answer (contract 9.5). Also every call once deskhand is stopping, including the one
    /// the stop ended, whose record says how it ended (contract 15.2).
    case dropped

    /// `nil` only for ``dropped``.
    public var structuredContent: JSONValue? {
        switch self {
        case .completed(let result): result.jsonValue
        case .error(let error): error.jsonValue
        case .replayed(_, let content): content
        case .dropped: nil
        }
    }

    public var isError: Bool {
        switch self {
        case .completed, .dropped: false
        case .error: true
        case .replayed(let replay, _): replay.isError
        }
    }
}

/// Why the watchdog stops the executing effect (contract 10.3, 12.4, 13).
///
/// A closed connection is not one of them: the executor reads the call's own
/// ``EffectCall/connection`` before every event and at every poll, so a close stops only the call
/// that connection carried, never another call that holds the section by then.
public enum Interruption: Hashable, Sendable {
    /// The state left `ok`; also a deadline of the allowance or of arming that passed.
    case state(BlockingState)
    /// The person at the Mac used the keyboard or pointer, or deskhand can no longer tell.
    case userActive(idleMs: Int)
    /// A lease ended. It stops the effect only if that effect runs under this lease, so the
    /// watchdog may forward every lease end.
    case leaseEnded(LeaseEnd)

    var reason: ToolErrorReason {
        switch self {
        case .state(let state): .blocked(state)
        case .userActive(let idleMs): .userActive(idleMs: idleMs)
        case .leaseEnded(let end): end.cause.abortReason
        }
    }
}

/// What ``InputExecutor/releaseOwedInput()`` did.
public enum OwedRelease: Sendable {
    /// The ledger is empty.
    case nothingOwed
    /// A call holds the admission section; its own abort releases what it pressed.
    case operationInSection
    /// The ledger could not be read, so what it owes is not known: nothing was released.
    /// ``InputExecutor/retryCleanup(now:)`` reads it again at every retry.
    case ledgerUnreadable
    case attempted(CleanupOutcome)
}
