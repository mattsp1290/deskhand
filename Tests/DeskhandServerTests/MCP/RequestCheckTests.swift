import DeskhandCore
import NIOHTTP1
import Testing

@testable import DeskhandServer

/// One request that fails a check of contract 2.4 and, where possible, also a later one, so that the
/// expected answer proves the checks run in table order.
struct CheckCase: Sendable, CustomTestStringConvertible {
    let check: Int
    let label: String
    let request: MCPTestRequest
    let status: HTTPResponseStatus
    /// The JSON-RPC error code; `nil` for an answer with no body.
    let code: Int?
    let id: JSONValue

    var testDescription: String { "check \(check): \(label)" }

    static let listBody =
        #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"#
        + #""io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#

    /// Fails check 13 as well, so a later code proves the earlier check ran first.
    static func raw(_ text: String, method: String = "tools/list") -> MCPTestRequest {
        MCPTestRequest.raw(text, method: method).with { $0.protocolVersion = [] }
    }

    static let all: [CheckCase] = [
        CheckCase(
            check: 11, label: "not JSON", request: raw(#"{"jsonrpc":"2.0","id":1,"#), status: .badRequest,
            code: -32_700, id: nil),
        CheckCase(
            check: 11, label: "duplicate member at the top", request: raw(#"{"jsonrpc":"2.0","id":1,"id":2}"#),
            status: .badRequest, code: -32_700, id: nil),
        CheckCase(
            check: 11, label: "lone surrogate in method",
            request: raw(#"{"jsonrpc":"2.0","id":1,"method":"tools/\ud800list"}"#), status: .badRequest,
            code: -32_700, id: nil),
        CheckCase(
            check: 11, label: "invalid UTF-8 outside arguments",
            request: MCPTestRequest(
                body: Array(#"{"jsonrpc":"2.0","id":1,"method":""#.utf8) + [0xFF] + Array(#""}"#.utf8)
            )
            .with { $0.protocolVersion = [] },
            status: .badRequest, code: -32_700, id: nil),
        CheckCase(
            check: 11, label: "number a double cannot hold", request: raw(#"{"jsonrpc":"2.0","id":1e400}"#),
            status: .badRequest, code: -32_700, id: nil),
        CheckCase(
            check: 11, label: "duplicate inside arguments of a method other than tools/call",
            request: raw(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"arguments":{"a":1,"a":2}}}"#),
            status: .badRequest, code: -32_700, id: nil),
        CheckCase(
            check: 11, label: "a second arguments member",
            request: raw(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status","arguments":{},"arguments":{}}}"#,
                method: "tools/call"),
            status: .badRequest, code: -32_700, id: nil),
        CheckCase(
            check: 11, label: "duplicate params.name",
            request: raw(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status","name":"pointer"}}"#,
                method: "tools/call"),
            status: .badRequest, code: -32_700, id: nil),
        CheckCase(
            check: 12, label: "batch", request: raw("[\(listBody)]"), status: .badRequest, code: -32_600, id: nil),
        CheckCase(
            check: 12, label: "a string", request: raw(#""tools/list""#), status: .badRequest, code: -32_600, id: nil),
        CheckCase(
            check: 12, label: "jsonrpc 1.0", request: raw(#"{"jsonrpc":"1.0","id":7,"method":"tools/list"}"#),
            status: .badRequest, code: -32_600, id: 7),
        CheckCase(
            check: 12, label: "jsonrpc missing", request: raw(#"{"id":"a","method":"tools/list"}"#),
            status: .badRequest, code: -32_600, id: "a"),
        CheckCase(
            check: 12, label: "method missing", request: raw(#"{"jsonrpc":"2.0","id":7}"#), status: .badRequest,
            code: -32_600, id: 7),
        CheckCase(
            check: 12, label: "method not a string", request: raw(#"{"jsonrpc":"2.0","id":7,"method":3}"#),
            status: .badRequest, code: -32_600, id: 7),
        CheckCase(
            check: 12, label: "id null", request: raw(#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#),
            status: .badRequest, code: -32_600, id: nil),
        CheckCase(
            check: 12, label: "id fractional", request: raw(#"{"jsonrpc":"2.0","id":1.5,"method":"tools/list"}"#),
            status: .badRequest, code: -32_600, id: nil),
        CheckCase(
            check: 12, label: "id beyond the exact integers",
            request: raw(#"{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/list"}"#), status: .badRequest,
            code: -32_600, id: nil),
        CheckCase(
            check: 12, label: "id a boolean", request: raw(#"{"jsonrpc":"2.0","id":true,"method":"tools/list"}"#),
            status: .badRequest, code: -32_600, id: nil),
        CheckCase(
            check: 12, label: "params a string",
            request: raw(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":"x"}"#), status: .badRequest,
            code: -32_600, id: 7),
        CheckCase(
            check: 13, label: "version header missing, _meta missing too",
            request: .raw(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#).with { $0.protocolVersion = [] },
            status: .badRequest, code: -32_020, id: 3),
        CheckCase(
            check: 13, label: "version header not a date",
            request: .call("tools/list").with { $0.protocolVersion = ["2026-7-28"] }, status: .badRequest,
            code: -32_020, id: 1),
        CheckCase(
            check: 13, label: "version header an impossible date",
            request: .call("tools/list").with { $0.protocolVersion = ["2026-02-30"] }, status: .badRequest,
            code: -32_020, id: 1),
        CheckCase(
            check: 13, label: "version header repeated",
            request: .call("tools/list").with { $0.protocolVersion = ["2026-07-28", "2026-07-28"] },
            status: .badRequest, code: -32_020, id: 1),
        CheckCase(
            check: 13, label: "notification without the version header",
            request: .call("tools/list", id: nil).with { $0.protocolVersion = [] }, status: .badRequest,
            code: -32_020, id: nil),
        CheckCase(
            check: 14, label: "unsupported version, Mcp-Method wrong too",
            request: .call("tools/list").with {
                $0.protocolVersion = ["2025-06-18"]
                $0.method = ["tools/call"]
            }, status: .badRequest, code: -32_022, id: 1),
        CheckCase(
            check: 14, label: "notification with an unsupported version",
            request: .call("tools/list", id: nil).with { $0.protocolVersion = ["2025-11-25"] }, status: .badRequest,
            code: -32_022, id: nil),
        CheckCase(
            check: 15, label: "notification with no _meta and a wrong Mcp-Method",
            request: .raw(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, method: "tools/list"),
            status: .accepted, code: nil, id: nil),
        CheckCase(
            check: 16, label: "params missing, Mcp-Method wrong too",
            request: .raw(#"{"jsonrpc":"2.0","id":12,"method":"tools/list"}"#, method: "tools/call"),
            status: .badRequest, code: -32_602, id: 12),
        CheckCase(
            check: 16, label: "_meta missing",
            request: .raw(#"{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{}}"#),
            status: .badRequest, code: -32_602, id: 12),
        CheckCase(
            check: 16, label: "params an array",
            request: .raw(#"{"jsonrpc":"2.0","id":12,"method":"tools/list","params":["2026-07-28"]}"#),
            status: .badRequest, code: -32_602, id: 12),
        CheckCase(
            check: 16, label: "body version not a string",
            request: .call("tools/list", params: ["_meta": [RequestChecks.protocolVersionKey: 20_260_728]]),
            status: .badRequest, code: -32_602, id: 1),
        CheckCase(
            check: 17, label: "body version differs from the header, Mcp-Method wrong too",
            request: .call("tools/list", params: ["_meta": [RequestChecks.protocolVersionKey: "2025-06-18"]]).with {
                $0.method = ["tools/call"]
            }, status: .badRequest, code: -32_020, id: 1),
        CheckCase(
            check: 18, label: "Mcp-Method missing", request: .call("tools/list").with { $0.method = [] },
            status: .badRequest, code: -32_020, id: 1),
        CheckCase(
            check: 18, label: "Mcp-Method differs in case",
            request: .call("tools/list").with { $0.method = ["Tools/list"] },
            status: .badRequest, code: -32_020, id: 1),
        CheckCase(
            check: 18, label: "Mcp-Method raw non-ASCII",
            request: .call("tools/list").with { $0.method = ["tools/lïst"] },
            status: .badRequest, code: -32_020, id: 1),
        CheckCase(
            check: 18, label: "unknown method with a wrong Mcp-Method",
            request: .call("ping").with { $0.method = ["tools/list"] }, status: .badRequest, code: -32_020, id: 1),
        CheckCase(
            check: 18, label: "Mcp-Name missing on tools/call", request: .tool("status").with { $0.name = [] },
            status: .badRequest, code: -32_020, id: 1),
        CheckCase(
            check: 18, label: "Mcp-Name differs", request: .tool("status").with { $0.name = ["pointer"] },
            status: .badRequest, code: -32_020, id: 1),
        CheckCase(
            check: 18, label: "params.name missing",
            request: .call("tools/call").with { $0.name = ["status"] }, status: .badRequest, code: -32_020, id: 1),
        CheckCase(
            check: 18, label: "params.name not a string, unknown tool too",
            request: .call("tools/call", params: ["name": 3]).with { $0.name = ["3"] }, status: .badRequest,
            code: -32_020, id: 1),
        CheckCase(
            check: 18, label: "Mcp-Name in a base64 form that does not decode",
            request: .tool("status").with { $0.name = ["=?base64?not base64?="] }, status: .badRequest,
            code: -32_020, id: 1),
        CheckCase(
            check: 19, label: "ping", request: .call("ping"), status: .notFound, code: -32_601, id: 1),
        CheckCase(
            check: 19, label: "initialize", request: .call("initialize", id: "init"), status: .notFound,
            code: -32_601, id: "init"),
        CheckCase(
            check: 20, label: "unknown tool", request: .tool("clipboard"), status: .ok, code: -32_602, id: 1),
        CheckCase(
            check: 20, label: "non-ASCII tool name sent encoded",
            request: .tool("pointér").with { $0.name = ["=?base64?cG9pbnTDqXI=?="] }, status: .ok, code: -32_602,
            id: 1),
        CheckCase(
            check: 20, label: "arguments an array",
            request: .call("tools/call", params: ["name": "status", "arguments": []]), status: .ok, code: -32_602,
            id: 1),
        CheckCase(
            check: 20, label: "arguments null",
            request: .call("tools/call", params: ["name": "status", "arguments": nil]), status: .ok, code: -32_602,
            id: 1),
    ]
}

@Suite struct RequestCheckTests {
    @Test(arguments: CheckCase.all)
    func refusedAtTheFirstFailingCheck(_ testCase: CheckCase) async {
        let dispatcher = FakeDispatcher()
        let response = await MCPTest.handle(testCase.request, dispatcher: dispatcher)
        #expect(response.status == testCase.status)
        #expect(response.errorCode == testCase.code)
        if testCase.code == nil {
            #expect(response.body == nil)
        } else {
            #expect(response.json?["jsonrpc"] == "2.0")
            #expect(response.id == testCase.id)
            #expect(response.result == nil)
        }
        #expect(dispatcher.calls.isEmpty)
    }

    @Test func headerMismatchNamesTheHeader() async {
        let response = await MCPTest.handle(.tool("status").with { $0.method = ["tools/list"] })
        #expect(response.json?["error"]?["data"]?["header"] == "Mcp-Method")
    }

    @Test func mcpNameIsIgnoredOutsideToolsCall() async {
        let response = await MCPTest.handle(.call("tools/list").with { $0.name = ["anything", "repeated"] })
        #expect(response.status == .ok)
        #expect(response.result?["resultType"] == "complete")
    }

    @Test func encodedHeaderValuesAreDecodedBeforeComparison() async {
        let request = MCPTestRequest.tool("status").with {
            $0.method = ["=?base64?dG9vbHMvY2FsbA==?="]
            $0.name = ["=?base64?c3RhdHVz?="]
            $0.protocolVersion = ["=?base64?MjAyNi0wNy0yOA==?="]
        }
        let dispatcher = FakeDispatcher(.error(FakeDispatcher.unexpected))
        let response = await MCPTest.handle(request, dispatcher: dispatcher)
        #expect(response.status == .ok)
        #expect(dispatcher.calls == [.status(StatusArguments())])
    }

    @Test func stringAndIntegerIDsAreEchoed() async {
        for id: JSONValue in ["call-1", 0, -42, 9_007_199_254_740_991] {
            let response = await MCPTest.handle(.call("server/discover", id: id))
            #expect(response.id == id)
            #expect(response.result != nil)
        }
    }

    @Test func notificationTouchesNothing() async {
        let dispatcher = FakeDispatcher()
        let response = await MCPTest.handle(.tool("pointer", ["holder_id": "h"], id: nil), dispatcher: dispatcher)
        #expect(response.status == .accepted)
        #expect(response.body == nil)
        #expect(dispatcher.calls.isEmpty)
    }

    @Test(arguments: [
        ("2026-07-28", true), ("2024-02-29", true), ("2023-02-29", false), ("1900-02-29", false),
        ("2000-02-29", true), ("2026-04-31", false), ("2026-00-10", false), ("2026-12-00", false),
        ("2026-07-28 ", false), ("２026-07-28", false), ("20260728", false),
    ])
    func protocolVersionDates(_ text: String, _ isDate: Bool) {
        #expect(HeaderValue.isDate(text) == isDate)
    }
}
