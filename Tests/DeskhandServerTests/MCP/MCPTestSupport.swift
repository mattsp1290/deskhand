import DeskhandCore
import Foundation
import NIOHTTP1
import Synchronization

@testable import DeskhandServer

/// One call the fake dispatcher received.
enum DispatchedCall: Hashable, Sendable {
    case status(StatusArguments)
    case displays
    case screenshot(ScreenshotArguments)
    case pointer(PointerArguments)
    case keyboard(KeyboardArguments)
    case lease(LeaseArguments)
    case refusal(ToolRefusal, ToolName, EffectHandles)
}

/// A ``ToolDispatcher`` that records each call and answers with one fixed reply.
final class FakeDispatcher: ToolDispatcher {
    enum Reply: Sendable {
        case status(StatusResult)
        case displays(DisplaysResult)
        case screenshot(CapturedScreenshot)
        case effect(EffectResult)
        case lease(LeaseToolResult)
        case error(ToolError)
        /// Blocks until the calling task is cancelled.
        case waitForCancellation
    }

    private struct Record {
        var calls: [DispatchedCall] = []
        var principals: [Principal] = []
        var cancellations = 0
    }

    private let reply: Reply
    private let record = Mutex(Record())
    private let startedContinuation: AsyncStream<Void>.Continuation
    /// Yields once each time a tool method starts.
    let started: AsyncStream<Void>

    init(_ reply: Reply = .error(FakeDispatcher.unexpected)) {
        self.reply = reply
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    static let unexpected = ToolError(.internalError, message: "The fake has no reply for this tool.", state: .ok)

    var calls: [DispatchedCall] { record.withLock { $0.calls } }
    var principals: [Principal] { record.withLock { $0.principals } }
    var cancellations: Int { record.withLock { $0.cancellations } }

    /// Waits for a cancellation to be recorded, up to `limit`.
    func waitForCancellation(limit: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if cancellations > 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cancellations > 0
    }

    private func answer<T>(_ call: DispatchedCall, _ principal: Principal, _ pick: (Reply) -> T?)
        async throws(ToolError)
        -> T
    {
        record.withLock {
            $0.calls.append(call)
            $0.principals.append(principal)
        }
        startedContinuation.yield()
        switch reply {
        case .error(let error): throw error
        case .waitForCancellation:
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { record.withLock { $0.cancellations += 1 } }
            throw ToolError(.internalError, message: "The call was cancelled.", state: .ok)
        default:
            guard let value = pick(reply) else { throw Self.unexpected }
            return value
        }
    }

    func status(_ arguments: StatusArguments, caller: ToolCaller) async throws(ToolError) -> StatusResult {
        try await answer(.status(arguments), caller.principal) {
            if case .status(let result) = $0 { return result }
            return nil
        }
    }

    func displays(caller: ToolCaller) async throws(ToolError) -> DisplaysResult {
        try await answer(.displays, caller.principal) {
            if case .displays(let result) = $0 { return result }
            return nil
        }
    }

    func screenshot(_ arguments: ScreenshotArguments, caller: ToolCaller) async throws(ToolError)
        -> CapturedScreenshot
    {
        try await answer(.screenshot(arguments), caller.principal) {
            if case .screenshot(let result) = $0 { return result }
            return nil
        }
    }

    func effect(_ arguments: EffectCallArguments, received: JSONObject, caller: ToolCaller) async -> EffectAnswer {
        let call: DispatchedCall =
            switch arguments {
            case .pointer(let pointer): .pointer(pointer)
            case .keyboard(let keyboard): .keyboard(keyboard)
            }
        do throws(ToolError) {
            return .completed(
                try await answer(call, caller.principal) {
                    if case .effect(let result) = $0 { return result }
                    return nil
                })
        } catch {
            return .error(error)
        }
    }

    func lease(_ arguments: LeaseArguments, caller: ToolCaller) async throws(ToolError) -> LeaseToolResult {
        try await answer(.lease(arguments), caller.principal) {
            if case .lease(let result) = $0 { return result }
            return nil
        }
    }

    func refusal(_ refusal: ToolRefusal, tool: ToolName, handles: EffectHandles, caller: ToolCaller) async
        -> ToolError
    {
        record.withLock {
            $0.calls.append(.refusal(refusal, tool, handles))
            $0.principals.append(caller.principal)
        }
        switch refusal {
        case .invalidArguments(let error):
            return ToolError(
                .invalidArgument(error.pointer), message: error.message, state: .ok, operationID: handles.operationID)
        case .unencodableResult:
            return ToolError(
                .internalError, message: "The result could not be serialized.", state: .ok,
                operationID: handles.operationID)
        }
    }
}

/// A request as the listener hands it over, built field by field.
struct MCPTestRequest: Sendable {
    var body: [UInt8]
    var protocolVersion: [String] = [ContractConstants.mcpProtocolVersion]
    var method: [String] = []
    var name: [String] = []

    static let principal = Principal(certificateSubject: "CN=crew-executor,O=forge")
    static let meta: JSONValue = [RequestChecks.protocolVersionKey: .string(ContractConstants.mcpProtocolVersion)]

    /// A request whose headers agree with its body.
    static func call(_ method: String, params: JSONObject = [:], id: JSONValue? = 1) -> MCPTestRequest {
        var params = params
        if params["_meta"] == nil { params["_meta"] = meta }
        var message: JSONObject = ["jsonrpc": "2.0", "method": .string(method), "params": .object(params)]
        message["id"] = id
        var request = MCPTestRequest(body: try! JSONValue.object(message).canonicalBytes())
        request.method = [method]
        if method == "tools/call", let name = params["name"]?.stringValue { request.name = [name] }
        return request
    }

    static func tool(_ name: String, _ arguments: JSONObject? = nil, id: JSONValue? = 1) -> MCPTestRequest {
        var params: JSONObject = ["name": .string(name)]
        params["arguments"] = arguments.map(JSONValue.object)
        return call("tools/call", params: params, id: id)
    }

    /// A raw body with the given headers.
    static func raw(_ text: String, method: String = "tools/list", name: String? = nil) -> MCPTestRequest {
        MCPTestRequest(body: Array(text.utf8), method: [method], name: name.map { [$0] } ?? [])
    }

    func with(_ change: (inout MCPTestRequest) -> Void) -> MCPTestRequest {
        var copy = self
        change(&copy)
        return copy
    }

    var authenticated: AuthenticatedRequest {
        AuthenticatedRequest(
            principal: Self.principal,
            headers: MCPRequestHeaders(protocolVersion: protocolVersion, method: method, name: name), body: body)
    }
}

/// A handler response, with its body parsed.
struct MCPTestResponse {
    let status: HTTPResponseStatus
    let body: [UInt8]?
    let json: JSONValue?

    init(_ response: HandlerResponse) {
        status = response.status
        body = response.body
        json = response.body.flatMap { try? JSONValue(parsing: $0) }
    }

    var id: JSONValue? { json?["id"] }
    var errorCode: Int? {
        guard case .number(let code)? = json?["error"]?["code"] else { return nil }
        return Int(code)
    }
    var result: JSONValue? { json?["result"] }
    var structuredContent: JSONValue? { result?["structuredContent"] }
    var isError: Bool? {
        guard case .bool(let flag)? = result?["isError"] else { return nil }
        return flag
    }
    var content: [JSONValue] {
        guard case .array(let blocks)? = result?["content"] else { return [] }
        return blocks
    }

    /// The text block's text, parsed as JSON.
    var contentText: JSONValue? {
        content.last?["text"]?.stringValue.flatMap { try? JSONValue(parsing: $0) }
    }
}

enum MCPTest {
    static func handle(
        _ request: MCPTestRequest, dispatcher: FakeDispatcher = FakeDispatcher(), serverVersion: String = "0.1.0"
    ) async -> MCPTestResponse {
        let handler = MCPHandler(dispatcher: dispatcher, serverVersion: serverVersion)
        return MCPTestResponse(await handler.handle(request.authenticated))
    }

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let schemas = repository.appendingPathComponent("docs/schemas")

    static func bytes(_ relativePath: String) throws -> [UInt8] {
        Array(try Data(contentsOf: schemas.appendingPathComponent(relativePath)))
    }

    static func json(_ relativePath: String) throws -> JSONValue {
        try JSONValue(parsing: try bytes(relativePath))
    }
}
