import DeskhandCore

extension DeskhandDispatcher {
    /// `pointer` and `keyboard`: runs the call through the executor, in this task, so a connection
    /// closed before admission drops the call and one closed later aborts it (contract 9.5, 12.4).
    /// The executor applies every refusal from step 1 on, the action ceiling of step 7 included,
    /// and measures what the result reports (contract 6.7).
    public func effect(_ arguments: EffectCallArguments, received: JSONObject, caller: ToolCaller) async
        -> EffectAnswer
    {
        let context = EffectRefusalContext(
            tool: arguments.tool, handles: EffectHandles(arguments: received), principal: caller.principal,
            nodeAddress: caller.nodeAddress)
        guard let nodeAddress = caller.nodeAddress else {
            return await executor.refusal(.missingNodeAddress, context: context).map(EffectAnswer.error) ?? .dropped
        }
        let digest: RequestDigest
        do {
            digest = try RequestDigest(tool: arguments.tool, arguments: received, key: digestKey)
        } catch {
            return await executor.refusal(.digestUnavailable, context: context).map(EffectAnswer.error) ?? .dropped
        }
        if await !executor.storesAvailable { await executor.reloadUnavailableStores() }
        let call = EffectCall(
            principal: caller.principal, nodeAddress: nodeAddress, arguments: arguments, digest: digest,
            connection: TaskCancellationLiveness())
        return await executor.perform(call)
    }
}
