import DeskhandCore
import NIOHTTP1

/// The MCP methods deskhand implements (contract 3).
enum MCPMethod: String, CaseIterable, Sendable {
    case discover = "server/discover"
    case listTools = "tools/list"
    case callTool = "tools/call"
}

/// The `arguments` of a `tools/call`: `{}` when the request omitted them (contract 3.3).
struct ToolArguments: Hashable, Sendable {
    let object: JSONObject
    /// The first strict-JSON fault inside `arguments` (contract 2.4), as an argument fault. While it
    /// is set, `object` holds one of several readings and nothing may act on it.
    let strictFault: ArgumentError?
    /// Read from `object`, leaving out a member that a strict-JSON fault makes ambiguous.
    let handles: EffectHandles
}

enum MCPCall: Hashable, Sendable {
    case discover
    case listTools
    case callTool(ToolName, ToolArguments)
}

/// A body that passed contract 2.4 checks 11 to 20.
enum CheckedRequest: Hashable, Sendable {
    /// Check 15: answered `202` with no body.
    case notification
    case request(JSONRPCID, MCPCall)
}

/// Contract 2.4 checks 11 to 20, in table order, on a request the listener admitted (checks 1 to 10).
/// Pure: it reads the body and the MCP headers and decides nothing else.
enum RequestChecks {
    static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let argumentsLocation = JSONPointer(["params", "arguments"])

    static func check(_ body: [UInt8], headers: MCPRequestHeaders) throws(ProtocolFault) -> CheckedRequest {
        let (value, argumentFaults) = try parseStrictly(body)
        let envelope = try readEnvelope(value)
        let id = envelope.id
        let version = try decode(headers.protocolVersion, header: "MCP-Protocol-Version", id: id)
        guard HeaderValue.isDate(version) else {
            throw mismatch("MCP-Protocol-Version", "MCP-Protocol-Version must be a date of the form YYYY-MM-DD.", id)
        }
        guard version.matchesScalars(of: ContractConstants.mcpProtocolVersion) else {
            throw ProtocolFault(
                .badRequest, .unsupportedProtocolVersion,
                detail: "This server supports \(ContractConstants.mcpProtocolVersion) only.", id: id)
        }
        guard let id else { return .notification }

        let params = envelope.params?.objectValue ?? [:]
        let bodyVersion = try readProtocolVersion(params, id: id)
        guard bodyVersion.matchesScalars(of: version) else {
            throw mismatch(
                "MCP-Protocol-Version",
                #"params._meta["\#(protocolVersionKey)"] is '\#(bodyVersion)' but MCP-Protocol-Version is '\#(version)'."#,
                id)
        }
        let methodHeader = try decode(headers.method, header: "Mcp-Method", id: id)
        guard methodHeader.matchesScalars(of: envelope.method) else {
            throw mismatch("Mcp-Method", "Mcp-Method is '\(methodHeader)' but method is '\(envelope.method)'.", id)
        }
        let method = MCPMethod.allCases.first { $0.rawValue.matchesScalars(of: envelope.method) }
        if method == .callTool { try matchName(headers, params: params, id: id) }
        switch method {
        case nil: throw ProtocolFault(.notFound, .methodNotFound, id: id)
        case .discover: return .request(id, .discover)
        case .listTools: return .request(id, .listTools)
        case .callTool:
            return .request(id, try toolCall(params, argumentFaults: argumentFaults, id: id))
        }
    }

    /// Check 11. A strictness fault inside `params.arguments` of a `tools/call` is returned, as a
    /// pointer into `arguments`, for the tool's argument check; any other fault is `-32700`.
    private static func parseStrictly(_ body: [UInt8]) throws(ProtocolFault) -> (JSONValue, [ArgumentError]) {
        let parsed: (value: JSONValue, faults: [JSONParseError])
        do {
            parsed = try JSONValue.parsingRequestBody(body)
        } catch {
            throw ProtocolFault(.badRequest, .parseError, detail: error.description, id: nil)
        }
        let isToolCall = parsed.value.objectValue?.member("method")?.stringValue?.matchesScalars(of: "tools/call")
        var argumentFaults: [ArgumentError] = []
        for fault in parsed.faults {
            guard isToolCall == true, let pointer = argumentPointer(of: fault) else {
                throw ProtocolFault(.badRequest, .parseError, detail: fault.description, id: nil)
            }
            argumentFaults.append(ArgumentError(at: pointer, fault.reason))
        }
        return (parsed.value, argumentFaults)
    }

    /// Where a strictness fault lies inside `params.arguments`, or `nil` when it lies outside. A
    /// repeated name is located at the repeating member, so a second `arguments` member is outside;
    /// invalid Unicode in a member name is located at the object holding it.
    private static func argumentPointer(of fault: JSONParseError) -> JSONPointer? {
        guard fault.kind.isStrictness, let pointer = fault.location.relative(to: argumentsLocation) else { return nil }
        switch fault.kind {
        case .duplicateMemberName, .equivalentMemberNames: return pointer.tokens.isEmpty ? nil : pointer
        case .invalidUnicode, .syntax, .numberOutOfRange: return pointer
        }
    }

    private struct Envelope {
        let id: JSONRPCID?
        let method: String
        let params: JSONValue?
    }

    /// Check 12: one JSON-RPC 2.0 request or notification object. A usable `id` is echoed even here.
    private static func readEnvelope(_ value: JSONValue) throws(ProtocolFault) -> Envelope {
        guard case .object(let message) = value else {
            let detail =
                if case .array = value { "Batches are not accepted." } else { "The body is not a JSON-RPC object." }
            throw ProtocolFault(.badRequest, .invalidRequest, detail: detail, id: nil)
        }
        var id: JSONRPCID?
        if let rawID = message.member("id") {
            guard let parsed = JSONRPCID(rawID) else {
                throw ProtocolFault(
                    .badRequest, .invalidRequest, detail: "id must be a string or an integer.", id: nil)
            }
            id = parsed
        }
        guard message.member("jsonrpc")?.stringValue?.matchesScalars(of: "2.0") == true else {
            throw ProtocolFault(.badRequest, .invalidRequest, detail: #"jsonrpc must be "2.0"."#, id: id)
        }
        guard let method = message.member("method")?.stringValue else {
            throw ProtocolFault(.badRequest, .invalidRequest, detail: "method must be a string.", id: id)
        }
        let params = message.member("params")
        switch params {
        case nil, .object?, .array?: break
        default: throw ProtocolFault(.badRequest, .invalidRequest, detail: "params must be an object.", id: id)
        }
        return Envelope(id: id, method: method, params: params)
    }

    /// Check 16.
    private static func readProtocolVersion(_ params: JSONObject, id: JSONRPCID) throws(ProtocolFault) -> String {
        let value = params.member("_meta")?.objectValue?.member(protocolVersionKey)
        guard let version = value?.stringValue else {
            let detail =
                #"params._meta["\#(protocolVersionKey)"] \#(value == nil ? "is required" : "must be a string")."#
            throw ProtocolFault(.badRequest, .invalidParams, detail: detail, id: id)
        }
        return version
    }

    /// The second half of check 18, on `tools/call`.
    private static func matchName(_ headers: MCPRequestHeaders, params: JSONObject, id: JSONRPCID)
        throws(ProtocolFault)
    {
        let nameHeader = try decode(headers.name, header: "Mcp-Name", id: id)
        guard let name = params.member("name")?.stringValue else {
            throw mismatch("Mcp-Name", "params.name must be a string for Mcp-Name to match it.", id)
        }
        guard nameHeader.matchesScalars(of: name) else {
            throw mismatch("Mcp-Name", "Mcp-Name is '\(nameHeader)' but params.name is '\(name)'.", id)
        }
    }

    /// Check 20. `params.name` is a string: check 18 compared it with `Mcp-Name`.
    private static func toolCall(_ params: JSONObject, argumentFaults: [ArgumentError], id: JSONRPCID)
        throws(ProtocolFault) -> MCPCall
    {
        let name = params.member("name")?.stringValue ?? ""
        guard let tool = ToolName.allCases.first(where: { $0.rawValue.matchesScalars(of: name) }) else {
            throw ProtocolFault(.ok, JSONRPCError.unknownTool(name), id: id)
        }
        let arguments: JSONObject
        switch params.member("arguments") {
        case nil: arguments = [:]
        case .object(let object)?: arguments = object
        default:
            throw ProtocolFault(.ok, .invalidParams, detail: "params.arguments must be an object.", id: id)
        }
        var handleMembers = arguments
        for fault in argumentFaults {
            if let member = fault.pointer.tokens.first { handleMembers[member] = nil }
        }
        let toolArguments = ToolArguments(
            object: arguments, strictFault: argumentFaults.first, handles: EffectHandles(arguments: handleMembers))
        return .callTool(tool, toolArguments)
    }

    private static func decode(_ values: [String], header: String, id: JSONRPCID?) throws(ProtocolFault) -> String {
        do {
            return try HeaderValue.decode(values)
        } catch {
            throw mismatch(header, "\(header) \(error == .missing ? "is required" : "is malformed").", id)
        }
    }

    private static func mismatch(_ header: String, _ detail: String, _ id: JSONRPCID?) -> ProtocolFault {
        ProtocolFault(.badRequest, .headerMismatch, detail: detail, header: header, id: id)
    }
}

extension JSONObject {
    /// The member whose name is exactly `name`, compared by Unicode scalars: a name that is only
    /// canonically equivalent is a different member.
    fileprivate func member(_ name: String) -> JSONValue? {
        guard let index = index(forKey: name), self[index].key.matchesScalars(of: name) else { return nil }
        return self[index].value
    }
}

extension String {
    fileprivate func matchesScalars(of other: String) -> Bool { unicodeScalars.elementsEqual(other.unicodeScalars) }
}
