/// A refusal discovered before execution or while serializing its result.
public enum EffectRefusal: Sendable {
    case invalidArguments(ArgumentError)
    case missingNodeAddress
    case digestUnavailable
    case unencodableResult
}

/// Independently readable context for an effect that cannot be executed.
public struct EffectRefusalContext: Sendable {
    public let tool: ToolName
    public let handles: EffectHandles
    public let principal: Principal
    /// Missing source addresses cannot produce an action-log entry.
    public let nodeAddress: NodeAddress?

    public init(tool: ToolName, handles: EffectHandles, principal: Principal, nodeAddress: NodeAddress?) {
        self.tool = tool
        self.handles = handles
        self.principal = principal
        self.nodeAddress = nodeAddress
    }
}
