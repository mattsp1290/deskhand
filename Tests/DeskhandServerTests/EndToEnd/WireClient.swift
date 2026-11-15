import DeskhandCore
import NIOCore
import NIOHTTP1
import Synchronization
import Testing

@testable import DeskhandServer

struct WireResponse {
    let outcome: Outcome
    let mcp: MCPTestResponse?
    var sent: (tool: String, arguments: JSONObject?)?

    init(_ outcome: Outcome, sent: (tool: String, arguments: JSONObject?)? = nil) {
        self.outcome = outcome
        self.sent = sent
        mcp = outcome.response.map { MCPTestResponse(HandlerResponse(status: $0.status, body: $0.body)) }
    }

    var status: HTTPResponseStatus? { outcome.status }
    var headers: HTTPHeaders? { outcome.response?.headers }
    var structuredContent: JSONValue? { mcp?.structuredContent }
    var isError: Bool? { mcp?.isError }
    var code: String? { structuredContent?["code"]?.stringValue }
    var operation: JSONValue? { structuredContent?["operation"] }
}

struct WireSession {
    var connection: TestConnection
    let token: String

    mutating func call(_ tool: String, _ arguments: JSONObject? = nil) async -> WireResponse {
        var response = await send(WireRequest.tool(tool, arguments, token: token))
        response.sent = (tool, arguments)
        return response
    }

    mutating func send(_ request: TestRequest) async -> WireResponse {
        WireResponse(await connection.roundTrip(request))
    }
}

enum WireRequest {
    static func tool(_ tool: String, _ arguments: JSONObject?, token: String) -> TestRequest {
        MCPListenerTests.mcpRequest(.tool(tool, arguments)).setting("Authorization", to: "Bearer \(token)")
    }
}

extension DeskhandStack {
    func call(
        _ tool: String, _ arguments: JSONObject? = nil, as client: TestPKI.Client = .valid,
        token: String = CredentialDirectory.firstToken
    ) async throws -> WireResponse {
        var response = try await send(WireRequest.tool(tool, arguments, token: token), as: client)
        response.sent = (tool, arguments)
        return response
    }

    func send(_ request: TestRequest, as client: TestPKI.Client? = .valid) async throws -> WireResponse {
        WireResponse(try await TestClient.roundTrip(request, to: address, pki: pki, as: client))
    }

    func session<T>(
        as client: TestPKI.Client = .valid, token: String = CredentialDirectory.firstToken,
        _ body: (inout WireSession) async throws -> T
    ) async throws -> T {
        try await TestClient.withConnection(to: address, pki: pki, as: client) { connection in
            var session = WireSession(connection: connection, token: token)
            defer { connection = session.connection }
            return try await body(&session)
        }
    }

    @discardableResult
    func acquire(_ holder: String = Wire.holder, ttlMs: Int = 120_000) async throws -> WireResponse {
        try await call("lease", ["op": "acquire", "holder_id": .string(holder), "ttl_ms": JSONValue(ttlMs)])
    }

    func screenshot(_ holder: String = Wire.holder) async throws -> String {
        let shot = try await call("screenshot", ["holder_id": .string(holder)])
        return try #require(shot.structuredContent?["frame_id"]?.stringValue, "screenshot failed: \(shot.outcome)")
    }

    func ready(_ holder: String = Wire.holder) async throws -> String {
        try await acquire(holder)
        return try await screenshot(holder)
    }

    func lookUp(_ operation: String, holder: String = Wire.holder) async throws -> JSONValue? {
        let status = try await call(
            "status", ["operation": ["holder_id": .string(holder), "operation_id": .string(operation)]])
        return status.structuredContent?["operation"]
    }

    func reportedConditions(token: String = CredentialDirectory.firstToken) async throws -> [String] {
        let status = try await call("status", token: token)
        guard case .array(let values)? = status.structuredContent?["conditions"] else { return [] }
        return values.compactMap(\.stringValue)
    }

    func activeStates() async throws -> [String] {
        guard case .array(let values)? = try await call("status").structuredContent?["active_states"] else { return [] }
        return values.compactMap(\.stringValue)
    }

    var refusalCodes: [ToolErrorCode] {
        get async {
            await entries.compactMap { entry in
                guard case .refusal(let refusal) = entry else { return nil }
                return refusal.code
            }
        }
    }
}

extension ActionLogEntry {
    var principal: Principal {
        switch self {
        case .intent(let entry): entry.principal
        case .outcome(let entry): entry.principal
        case .refusal(let entry): entry.principal
        }
    }
}

enum Wire {
    static let holder = "crew:alpha"
    static let otherHolder = "crew:beta"

    static func type(_ text: String, frame: String, _ operation: String, holder: String = holder) -> JSONObject {
        effect(["type": "type", "text": .string(text)], frame: frame, operation, holder: holder)
    }

    static func press(_ key: String, holdMs: Int = 0, frame: String, _ operation: String, holder: String = holder)
        -> JSONObject
    {
        effect(
            ["type": "press", "key": .string(key), "hold_ms": JSONValue(holdMs)], frame: frame, operation,
            holder: holder)
    }

    static func click(
        x: Int = 400, y: Int = 300, frame: String, _ operation: String, holder: String = holder,
        permittedApps: [String]? = nil
    ) -> JSONObject {
        var arguments = effect(
            ["type": "click", "x": JSONValue(x), "y": JSONValue(y)], frame: frame, operation, holder: holder)
        arguments["permitted_apps"] = permittedApps.map { .array($0.map(JSONValue.string)) }
        return arguments
    }

    static func effect(_ action: JSONValue, frame: String, _ operation: String, holder: String) -> JSONObject {
        [
            "holder_id": .string(holder), "frame_id": .string(frame), "operation_id": .string(operation),
            "action": action,
        ]
    }

    static let unknownFrame = "frm_AAAAAAAAAAAAAAAAAAAAAA"
}

enum ContractShape {
    static let states = Set(BlockingState.allCases.map(\.rawValue))
    static let detailMembers: [String: Set<String>] = [
        "invalid_argument": ["argument"], "stale_frame": ["reason"],
        "out_of_frame": ["point_index", "output_pixel_size"],
        "image_too_large": ["image_bytes", "max_image_bytes"], "user_active": ["idle_ms"], "denied_app": ["denied_by"],
        "denied_shortcut": ["shortcut"], "lease_held_by_other": ["expires_in_ms"],
    ]

    static func toolErrorViolations(_ response: WireResponse, code: String) -> [String] {
        var broken: [String] = []
        if response.status != .ok { broken.append("HTTP \(String(describing: response.status)), not 200") }
        if response.isError != true { broken.append("isError is not true") }
        guard let content = response.structuredContent else { return broken + ["no structuredContent"] }
        if response.mcp?.contentText != content { broken.append("the text block is not structuredContent") }
        if content["code"]?.stringValue != code { broken.append("code \(String(describing: content["code"]))") }
        for member in ["message", "state"] where content[member]?.stringValue == nil {
            broken.append("no \(member)")
        }
        if states.contains(code), content["state"]?.stringValue != code { broken.append("state is not the code") }
        let replayed = content["replayed"] == true
        if replayed != (content["current_state"] != nil) {
            broken.append("current_state is not there exactly on a replay")
        }
        if (code == "rate_limited") != (content["retry_after_ms"] != nil) { broken.append("retry_after_ms") }
        let details = content["details"]?.objectValue
        if let expected = detailMembers[code] {
            if !expected.isSubset(of: Set(details?.keys.map { $0 } ?? [])) {
                broken.append("details lacks \(expected)")
            }
        } else if details != nil {
            broken.append("details on \(code)")
        }
        if ["operation_in_progress", "operation_id_conflict", "interrupted", "cancelled"].contains(code),
            content["operation_id"] == nil || content["operation"] == nil
        {
            broken.append("no operation_id or operation")
        }
        if ["interrupted", "cancelled"].contains(code), !replayed { broken.append("not replayed") }
        if code == "denied_app", content["measured"]?["window_title"] != .null {
            broken.append("a window title on denied_app")
        }
        if code == "denied_app", content["measured"]?["drag_end"] != nil { broken.append("drag_end on denied_app") }
        let admitted = content["replayed"] != nil
        if admitted, content["operation"] == nil { broken.append("replayed without operation") }
        let measuredRequired = ["denied_app", "log_unavailable"].contains(code) || (admitted && code != "interrupted")
        if measuredRequired != (content["measured"] != nil) {
            broken.append(measuredRequired ? "no measured" : "measured on a call that was not admitted")
        }
        if let sent = response.sent {
            let effect = ["pointer", "keyboard"].contains(sent.tool)
            let operationID = sent.arguments?["operation_id"]
            if effect, let operationID, content["operation_id"] != operationID {
                broken.append("operation_id is not echoed")
            }
            if !effect, content["operation_id"] != nil || content["operation"] != nil || admitted {
                broken.append("operation members on \(sent.tool)")
            }
        }
        return broken
    }

    static func expectToolError(
        _ response: WireResponse, _ code: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let broken = toolErrorViolations(response, code: code)
        #expect(
            broken.isEmpty, "\(code): \(broken) in \(String(describing: response.structuredContent))",
            sourceLocation: sourceLocation)
    }
}

final class Latch: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if now { continuation.resume() }
        }
    }
}

func waitForHangUp(limit: Duration = .seconds(20)) async {
    let deadline = ContinuousClock.now + limit
    while !Task.isCancelled, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
