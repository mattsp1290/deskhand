import DeskhandCore
import NIOHTTP1

/// The sessionless MCP `2026-07-28` endpoint behind the listener: contract 2.4 checks 11 to 20, then
/// `server/discover`, `tools/list` and `tools/call` (contract 3).
///
/// Every answer is one `application/json` body or, for a notification, `202` with none. Each
/// `tools/call` runs in the request's own task, which the listener cancels when the caller closes
/// the connection; the dispatcher sees that cancellation.
public struct MCPHandler: RequestHandler {
    private let dispatcher: any ToolDispatcher
    private let serverVersion: String

    /// `serverVersion` is the build version reported as `serverInfo.version` by `server/discover`.
    public init(dispatcher: any ToolDispatcher, serverVersion: String = DeskhandServerModule.version) {
        self.dispatcher = dispatcher
        self.serverVersion = serverVersion
    }

    public func handle(_ request: AuthenticatedRequest) async -> HandlerResponse {
        let checked: CheckedRequest
        do {
            checked = try RequestChecks.check(request.body, headers: request.headers)
        } catch {
            return error.response
        }
        guard case .request(let id, let call) = checked else { return .accepted }
        switch call {
        case .discover:
            return respond(ToolCatalog.discoverResult(serverVersion: serverVersion), id: id)
        case .listTools:
            switch ToolCatalog.listResult {
            case .success(let result): return respond(result, id: id)
            case .failure(let error): return internalError(error.description, id: id)
            }
        case .callTool(let tool, let arguments):
            return await callTool(tool, arguments, principal: request.principal, id: id)
        }
    }

    /// From here on the status is `200` and a refusal is an `isError` result (contract 2.4).
    private func callTool(_ tool: ToolName, _ arguments: ToolArguments, principal: Principal, id: JSONRPCID) async
        -> HandlerResponse
    {
        let runner = ToolRunner(dispatcher: dispatcher, principal: principal)
        let outcome = await runner.run(tool, arguments)
        if let body = try? JSONRPCEnvelope.result(outcome.result(), id: id) { return .json(body) }
        let fallback = ToolOutcome.failure(await runner.refusal(.unencodableResult, tool, arguments))
        if let body = try? JSONRPCEnvelope.result(fallback.result(), id: id) { return .json(body) }
        return internalError("The tool result could not be serialized.", id: id)
    }

    private func respond(_ result: JSONValue, id: JSONRPCID) -> HandlerResponse {
        do {
            return .json(try JSONRPCEnvelope.result(result, id: id))
        } catch {
            return internalError("The result could not be serialized.", id: id)
        }
    }

    private func internalError(_ detail: String, id: JSONRPCID) -> HandlerResponse {
        ProtocolFault(.ok, .internalError, detail: detail, id: id).response
    }
}
