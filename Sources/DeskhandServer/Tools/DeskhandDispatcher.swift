import DeskhandCore

/// The real ``ToolDispatcher`` (deskhand-zuyx): `status`, `displays`, `screenshot` and `lease`
/// against the per-Mac ``DeskOwner``, and `pointer` and `keyboard` through the serial
/// ``InputExecutor``.
///
/// It holds no state of its own: the lease, the frames and the state live in the owner, the
/// operation records, the ledger and the action ceiling in the executor. Every call reads them at
/// its own clock reading, so calls need no ordering beyond theirs.
public struct DeskhandDispatcher: ToolDispatcher {
    /// What `status` reports about this build and this Mac.
    public struct Configuration: Sendable {
        /// `status.mac`.
        public var mac: String
        /// `status.server_version`.
        public var serverVersion: String
        /// `status.started_at`: when this process started.
        public var startedAt: Timestamp
        /// `status.limits`, and `max_age_ms` of every frame.
        public var limits: Limits

        public init(
            mac: String, serverVersion: String = DeskhandServerModule.version, startedAt: Timestamp,
            limits: Limits = Limits()
        ) {
            self.mac = mac
            self.serverVersion = serverVersion
            self.startedAt = startedAt
            self.limits = limits
        }
    }

    /// The platform behind the read tools. The executor has seams of its own.
    public struct Platform: Sendable {
        public var capturer: any ScreenCapturer
        /// The frontmost app at capture (contract 6.3): the same measurer the executor uses, so a
        /// frame records the app exactly as a `keyboard` call's `frontmost_changed` check reads it.
        public var identity: any IdentityMeasurer
        /// The person at the Mac, for the `user_active` condition (contract 11.5).
        public var activity: any UserActivitySource
        public var conditions: any ConditionsProvider

        public init(
            capturer: any ScreenCapturer, identity: any IdentityMeasurer, activity: any UserActivitySource,
            conditions: any ConditionsProvider
        ) {
            self.capturer = capturer
            self.identity = identity
            self.activity = activity
            self.conditions = conditions
        }
    }

    let configuration: Configuration
    let owner: DeskOwner
    let executor: InputExecutor
    let platform: Platform
    let digestKey: DigestKey
    let leaseDidChange: @Sendable () async -> Void

    /// - Parameters:
    ///   - owner: also the executor's ``InputExecutor/Seams/state`` and ``InputExecutor/Seams/frames``.
    ///   - digestKey: the per-install key of the operation digest (contract 12.1).
    ///   - leaseDidChange: runs after every `lease` call; the app passes ``Watchdog/refreshState()``
    ///     so the deadline follows a renewal or a release at once (contract 13.1).
    public init(
        configuration: Configuration, owner: DeskOwner, executor: InputExecutor, platform: Platform,
        digestKey: DigestKey, leaseDidChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.configuration = configuration
        self.owner = owner
        self.executor = executor
        self.platform = platform
        self.digestKey = digestKey
        self.leaseDidChange = leaseDidChange
    }

    // MARK: status

    /// Answers in every state and changes nothing (contract 6.1).
    public func status(_ arguments: StatusArguments, caller: ToolCaller) async throws(ToolError) -> StatusResult {
        let view = owner.statusView(
            for: arguments.holderID.map { LeaseHolder(principal: caller.principal, holderID: $0) })
        var operation: StatusOperation?
        if let query = arguments.operation {
            operation = try await lookUp(query.key(for: caller.principal), state: view.state)
        }
        return StatusResult(
            serverVersion: configuration.serverVersion, mac: configuration.mac, time: view.reading.wall,
            startedAt: configuration.startedAt, activeStates: view.activeStates,
            conditions: await conditions(reduced: view.conditions), armedUntil: view.armedUntil, lease: view.lease,
            operation: operation, displayConfigGeneration: owner.displays.generation, limits: configuration.limits)
    }

    /// Each condition from the one place that knows it now (contract 11): `login_window` from the
    /// latest reduction, `cleanup_pending` from the executor's ledger, `user_active` from the idle
    /// signal at this moment, and `credentials_warning` and `log_unavailable` from the provider.
    private func conditions(reduced: Set<Condition>) async -> Set<Condition> {
        var conditions = reduced.intersection([.loginWindow])
        conditions.formUnion(platform.conditions.conditions().intersection([.credentialsWarning, .logUnavailable]))
        if await executor.owesReleases { conditions.insert(.cleanupPending) }
        if Self.personIsActive(idleMilliseconds: platform.activity.idleMilliseconds()) {
            conditions.insert(.userActive)
        }
        return conditions
    }

    /// The executor's rule (contract 13.2): input within `USER_ACTIVITY_LOOKBACK_MS`, or an idle
    /// signal that cannot be read, is activity.
    static func personIsActive(idleMilliseconds: Int?) -> Bool {
        guard let idle = idleMilliseconds else { return true }
        return idle < ContractConstants.userActivityLookbackMs
    }

    /// `status.operation`: never executes anything, needs no lease and counts toward nothing. A
    /// record file that a failed write left unavailable is loaded again first, while no call is in
    /// the admission section (contract 12.3).
    private func lookUp(_ key: OperationKey, state: DeskhandState) async throws(ToolError) -> StatusOperation {
        if await !executor.storesAvailable { await executor.reloadUnavailableStores() }
        do {
            return try await executor.operationStatus(for: key)
        } catch {
            throw ToolError(.internalError, message: "The operation records are unavailable.", state: state)
        }
    }

    // MARK: displays

    public func displays(caller: ToolCaller) async throws(ToolError) -> DisplaysResult {
        try refuseUnlessOK()
        let configuration: DisplayConfiguration
        do {
            configuration = try owner.displays.configuration()
        } catch {
            throw internalError(error.detail)
        }
        // A call that has not answered when the state leaves `ok` gets the new state's name (10.3).
        try refuseUnlessOK()
        return DisplaysResult(displayConfigGeneration: configuration.generation, displays: configuration.displays)
    }

    // MARK: lease

    /// A refused operation is an outcome, not an error (contract 5.1). Every live lease the call
    /// ends stops an effect executing under it (contract 5.3).
    public func lease(_ arguments: LeaseArguments, caller: ToolCaller) async throws(ToolError) -> LeaseToolResult {
        let application = owner.applyLease(arguments, principal: caller.principal)
        for end in application.ended { await executor.interrupt(.leaseEnded(end)) }
        await leaseDidChange()
        return application.result
    }

    // MARK: refusals

    /// Contract 9.5: `status` and `lease` refuse only with `invalid_argument`; every other tool
    /// with the state's name first. For `pointer` and `keyboard` the executor words it, so that it
    /// carries `operation` for an existing record and writes the refusal entry (contract 12.10).
    public func refusal(_ refusal: ToolRefusal, tool: ToolName, handles: EffectHandles, caller: ToolCaller) async
        -> ToolError
    {
        let state = owner.snapshot().state
        switch (refusal, tool) {
        case (.invalidArguments(let error), .status), (.invalidArguments(let error), .lease):
            return ToolError(.invalidArgument(error.pointer), message: error.description, state: state)
        case (.invalidArguments(let error), .displays), (.invalidArguments(let error), .screenshot):
            if let blocking = state.blocking { return Self.blocked(blocking) }
            return ToolError(.invalidArgument(error.pointer), message: error.description, state: state)
        case (.invalidArguments(let error), .pointer), (.invalidArguments(let error), .keyboard):
            if let nodeAddress = caller.nodeAddress {
                return await executor.refusal(
                    for: error, tool: tool, handles: handles, principal: caller.principal, nodeAddress: nodeAddress)
            }
            // Without the node the refusal entry cannot be written; it is best effort (contract
            // 12.10), so the refusal is the same without it.
            let reason: ToolErrorReason = state.blocking.map { .blocked($0) } ?? .invalidArgument(error.pointer)
            return ToolError(
                reason, message: reason.code == .invalidArgument ? error.description : Self.message(for: state),
                state: state, operationID: handles.operationID, operation: await existingRecord(handles, caller: caller)
            )
        case (.unencodableResult, .pointer), (.unencodableResult, .keyboard):
            return ToolError(
                .internalError, message: "The tool result could not be serialized.", state: state,
                operationID: handles.operationID, operation: await existingRecord(handles, caller: caller))
        case (.unencodableResult, _):
            return ToolError(.internalError, message: "The tool result could not be serialized.", state: state)
        }
    }

    // MARK: shared

    func refuseUnlessOK() throws(ToolError) {
        if let blocking = owner.snapshot().state.blocking { throw Self.blocked(blocking) }
    }

    static func blocked(_ state: BlockingState, operationID: OperationID? = nil) -> ToolError {
        ToolError(.blocked(state), message: message(for: state.state), state: state.state, operationID: operationID)
    }

    static func message(for state: DeskhandState) -> String { "deskhand is \(state.rawValue)." }

    func internalError(_ detail: String, operationID: OperationID? = nil) -> ToolError {
        ToolError(.internalError, message: detail, state: owner.snapshot().state, operationID: operationID)
    }
}
