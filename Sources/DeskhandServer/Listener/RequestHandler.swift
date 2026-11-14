import DeskhandCore
import NIOHTTP1

/// The MCP headers of a request, for the JSON-RPC layer's checks 13 and 14 (contract 2.4). Each
/// holds every value of that header in arrival order, empty when absent; header names were matched
/// case-insensitively, values are untouched.
public struct MCPRequestHeaders: Hashable, Sendable {
    public let protocolVersion: [String]
    public let method: [String]
    public let name: [String]

    public init(protocolVersion: [String], method: [String], name: [String]) {
        self.protocolVersion = protocolVersion
        self.method = method
        self.name = name
    }

    init(_ headers: HTTPHeaders) {
        self.init(
            protocolVersion: headers["MCP-Protocol-Version"],
            method: headers["Mcp-Method"],
            name: headers["Mcp-Name"]
        )
    }
}

/// A request that passed contract 2.4 checks 1 to 10: mutual TLS with the configured client
/// subject, header size, path, method, `Host`, `Origin`, bearer token, `Content-Type`, body size
/// and `Accept`. Nothing in the body has been looked at.
public struct AuthenticatedRequest: Sendable {
    public let principal: Principal
    public let headers: MCPRequestHeaders
    public let body: [UInt8]

    public init(principal: Principal, headers: MCPRequestHeaders, body: [UInt8]) {
        self.principal = principal
        self.headers = headers
        self.body = body
    }
}

/// What the listener sends back. A body is sent as `application/json`; nil sends none.
public struct HandlerResponse: Sendable {
    public let status: HTTPResponseStatus
    public let body: [UInt8]?

    public init(status: HTTPResponseStatus, body: [UInt8]?) {
        self.status = status
        self.body = body
    }

    public static func json(_ body: [UInt8], status: HTTPResponseStatus = .ok) -> HandlerResponse {
        HandlerResponse(status: status, body: body)
    }

    /// A JSON-RPC notification's answer (contract 2.4).
    public static let accepted = HandlerResponse(status: .accepted, body: nil)
}

/// The JSON-RPC layer (deskhand-8wvk): contract 2.4 checks 11 onward and everything after them.
///
/// Called once per request, in its own task. The listener cancels that task when the caller closes
/// the connection before the response is sent, which for an effect call must abort the input
/// sequence (contract 2.1). A response body over the response limit is never sent: the caller gets
/// `500` instead.
public protocol RequestHandler: Sendable {
    func handle(_ request: AuthenticatedRequest) async -> HandlerResponse
}
