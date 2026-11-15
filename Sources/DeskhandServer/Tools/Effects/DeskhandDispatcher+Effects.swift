import DeskhandCore

extension DeskhandDispatcher {
    /// `pointer` and `keyboard`: runs the call through the executor, in this task, so a connection
    /// closed before admission drops the call and one closed later aborts it (contract 9.5, 12.4).
    /// The executor applies every refusal from step 1 on, the action ceiling of step 7 included,
    /// and measures what the result reports (contract 6.7).
    public func effect(_ arguments: EffectCallArguments, received: JSONObject, caller: ToolCaller) async
        -> EffectAnswer
    {
        guard let nodeAddress = caller.nodeAddress else {
            return .error(await missingNodeAddress(EffectHandles(arguments: received), caller: caller))
        }
        let digest: RequestDigest
        do {
            digest = try RequestDigest(tool: arguments.tool, arguments: received, key: digestKey)
        } catch {
            return .error(
                internalError("The request digest could not be computed.", operationID: arguments.operationID))
        }
        if await !executor.storesAvailable { await executor.reloadUnavailableStores() }
        let call = EffectCall(
            principal: caller.principal, nodeAddress: nodeAddress, arguments: arguments, digest: digest,
            connection: TaskCancellationLiveness())
        return await executor.perform(call)
    }

    func existingRecord(_ handles: EffectHandles, caller: ToolCaller) async -> OperationContext? {
        guard let holderID = handles.holderID, let operationID = handles.operationID else { return nil }
        let key = OperationKey(principal: caller.principal, holderID: holderID, operationID: operationID)
        return await executor.recordedOperation(for: key).map { .existing($0) }
    }

    private func missingNodeAddress(_ handles: EffectHandles, caller: ToolCaller) async -> ToolError {
        let state = owner.snapshot().state
        let reason: ToolErrorReason = state.blocking.map { .blocked($0) } ?? .internalError
        let message =
            state.blocking == nil ? "The connection's source address could not be read." : Self.message(for: state)
        return ToolError(
            reason, message: message, state: state, operationID: handles.operationID,
            operation: await existingRecord(handles, caller: caller))
    }
}

extension EffectCallArguments {
    fileprivate var operationID: OperationID {
        switch self {
        case .pointer(let arguments): arguments.operationID
        case .keyboard(let arguments): arguments.operationID
        }
    }
}
