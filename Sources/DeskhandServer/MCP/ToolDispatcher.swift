import DeskhandCore

/// A successful `screenshot`: the frame's metadata and the encoded image it describes.
public struct CapturedScreenshot: Hashable, Sendable {
    public var result: ScreenshotResult
    /// The encoded image, before base64. Its length is `result.imageBytes`.
    public var image: [UInt8]

    public init(result: ScreenshotResult, image: [UInt8]) {
        self.result = result
        self.image = image
    }
}

/// A refusal that the JSON-RPC layer finds but cannot word on its own: every tool error carries the
/// state, and for effects the operation record, which only the dispatcher knows.
public enum ToolRefusal: Hashable, Sendable {
    /// The arguments break the tool's input schema, a contract rule, or strict JSON inside
    /// `params.arguments` (contract 2.4). The dispatcher applies the refusal order of contract 9.5:
    /// for `displays`, `screenshot`, `pointer` and `keyboard` a blocking state comes first.
    case invalidArguments(ArgumentError)
    /// The tool's result could not be serialized (a number that is not finite). The answer is
    /// `internal_error`.
    case unencodableResult
}

/// Who made a `tools/call`, and from where.
public struct ToolCaller: Hashable, Sendable {
    /// Every handle is scoped to it (contract 4).
    public let principal: Principal
    /// The connection's source address, for the action log (contract 12.10). `nil` when the
    /// listener could not read one: an effect call is then refused with `internal_error`, because
    /// its intent entry could not name the caller's node.
    public let nodeAddress: NodeAddress?

    public init(principal: Principal, nodeAddress: NodeAddress?) {
        self.principal = principal
        self.nodeAddress = nodeAddress
    }
}

/// Runs the six tools of contract section 6 for an authenticated caller (deskhand-zuyx).
///
/// Each call runs in the task of the HTTP request that carried it. That task is cancelled when the
/// caller closes the connection before the response is sent (contract 2.1): an effect that is not
/// admitted yet must then not be admitted, and one that is executing must abort (contract 4.3, 12.4).
///
/// Arguments arrive validated against the tool's input schema; a refusal from that point on is a
/// thrown ``ToolError``, answered as an `isError` result.
public protocol ToolDispatcher: Sendable {
    func status(_ arguments: StatusArguments, caller: ToolCaller) async throws(ToolError) -> StatusResult
    func displays(caller: ToolCaller) async throws(ToolError) -> DisplaysResult
    func screenshot(_ arguments: ScreenshotArguments, caller: ToolCaller) async throws(ToolError)
        -> CapturedScreenshot

    /// `pointer` and `keyboard`. `received` is `params.arguments` exactly as it arrived (`{}` when
    /// omitted): the operation digest covers it, not the validated arguments (contract 4.3). A
    /// replay answers with the stored `structuredContent`, never one derived again (contract 12.5).
    func effect(_ arguments: EffectCallArguments, received: JSONObject, caller: ToolCaller) async -> EffectAnswer

    func lease(_ arguments: LeaseArguments, caller: ToolCaller) async throws(ToolError) -> LeaseToolResult

    /// The tool error for a refusal found before or after the tool ran. `handles` are the
    /// `holder_id` and `operation_id` that could be read from the arguments, so that the error can
    /// echo `operation_id` and describe an existing record (contract 9.5). Returns nil when an
    /// effect response is suppressed by process stop; read refusals always return an error.
    func refusal(_ refusal: ToolRefusal, tool: ToolName, handles: EffectHandles, caller: ToolCaller) async
        -> ToolError?
}
