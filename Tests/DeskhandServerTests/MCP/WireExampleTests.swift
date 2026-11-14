import DeskhandCore
import Foundation
import NIOHTTP1
import Testing

@testable import DeskhandServer

/// Results that rebuild the `structuredContent` of the wire examples. Timestamps are milliseconds
/// since the epoch of the examples' RFC 3339 strings.
private enum WireResults {
    static let frame = FrameID("frm_Zk3vQ8sN1xT5bYc2Lw9RaA")!
    static let textEdit = AppRef(bundleID: "com.apple.TextEdit", teamID: nil, name: "TextEdit")
    static let heldLease = LeaseView.heldByCaller(
        acquiredAt: at(1_794_668_531_482), expiresAt: at(1_794_668_561_482), expiresInMs: 30_000)
    static let image = Array("not really a JPEG".utf8)

    static func at(_ milliseconds: Int64) -> Timestamp { Timestamp(millisecondsSinceEpoch: milliseconds) }

    static func status(operation: StatusOperation?) -> StatusResult {
        StatusResult(
            serverVersion: "0.1.0", mac: "lunus-macbook-pro", time: at(1_794_668_531_482),
            startedAt: at(1_794_663_602_000), activeStates: .none, conditions: [], armedUntil: at(1_794_672_000_000),
            lease: heldLease, operation: operation, displayConfigGeneration: DisplayConfigGeneration(3),
            limits: Limits())
    }

    static let pointerClick = EffectResult(
        operationID: OperationID("call_01HZX3M9Q3")!, frameID: frame, eventsPosted: 3, replayed: false,
        measured: SuccessMeasured(
            pointer: Measured(
                frontmostApp: textEdit, targetApp: textEdit, windowTitle: "notes.txt",
                globalPoint: GlobalPoint(x: 883.8114649681529, y: 571.3432982917215),
                measuredAt: at(1_794_668_539_730)),
            action: .move(FramePoint(x: 1204, y: 778)))!,
        completedAt: at(1_794_668_539_781))

    static let staleFrame = ToolError(
        .staleFrame(.pixelsChanged(pointIndex: 0)),
        message: "The pixels around the target changed since the frame was captured. Take a new screenshot.",
        state: .ok, operationID: OperationID("call_01HZX3M9Q8")!)

    static let screenshot = CapturedScreenshot(
        result: ScreenshotResult(
            frameID: frame, sha256: SHA256Hex(hex: "8db1f90ff7b0eb8bba6ff6d12c7ca55223f3c4a755ffa66f0f2ab19d83c8f089")!,
            displayID: DisplayID(1), displayConfigGeneration: DisplayConfigGeneration(3),
            captureRect: GlobalRect(x: 0, y: 0, width: 1728, height: 1117),
            sourcePixelSize: PixelSize(width: 3456, height: 2234),
            outputPixelSize: PixelSize(width: 2355, height: 1522),
            pointPixelScale: 2, downscale: 0.6817070194446376, encoding: .jpeg(.q85), imageBytes: 1_184_213,
            capturedAt: at(1_794_668_534_019), maxAgeMs: 60_000, pointerPosition: FramePoint(x: 1630, y: 912),
            frontmostApp: textEdit),
        image: image)
}

/// One `tools-call.*` pair of `docs/schemas/examples/wire/`.
struct ToolCallExample: Sendable, CustomTestStringConvertible {
    let name: String
    let reply: FakeDispatcher.Reply
    /// What the dispatcher must receive, from core's own reading of the example's arguments.
    let expectedCall: @Sendable (JSONObject) throws -> DispatchedCall

    var testDescription: String { name }

    static let all: [ToolCallExample] = [
        ToolCallExample(name: "status.holder", reply: .status(WireResults.status(operation: nil))) {
            .status(try StatusArguments(arguments: $0))
        },
        ToolCallExample(
            name: "status.operation-lookup",
            reply: .status(WireResults.status(operation: .found(OperationView(status: .completed, eventsPosted: 3))))
        ) { .status(try StatusArguments(arguments: $0)) },
        ToolCallExample(
            name: "lease.acquire",
            reply: .lease(
                LeaseToolResult(
                    result: LeaseResult(operation: .acquire, outcome: .acquired), lease: WireResults.heldLease))
        ) { .lease(try LeaseArguments(arguments: $0)) },
        ToolCallExample(
            name: "lease.held-by-other",
            reply: .lease(
                LeaseToolResult(
                    result: LeaseResult(operation: .acquire, outcome: .refused(.leaseHeldByOther(expiresInMs: 21_500))),
                    lease: .notHeldByCaller))
        ) { .lease(try LeaseArguments(arguments: $0)) },
        ToolCallExample(name: "pointer.click", reply: .effect(WireResults.pointerClick)) {
            .pointer(try PointerArguments(arguments: $0))
        },
        ToolCallExample(name: "pointer.stale-frame", reply: .error(WireResults.staleFrame)) {
            .pointer(try PointerArguments(arguments: $0))
        },
        ToolCallExample(name: "screenshot.default", reply: .screenshot(WireResults.screenshot)) {
            .screenshot(try ScreenshotArguments(arguments: $0))
        },
    ]
}

/// Each method's answer compared with the whole-message examples of contract 3.
@Suite struct WireExampleTests {
    /// The example request as the listener would hand it over, with headers that agree with the body.
    static func request(_ file: String) throws -> (MCPTestRequest, JSONValue) {
        let bytes = try MCPTest.bytes("examples/wire/\(file)")
        let message = try JSONValue(parsing: bytes)
        let method = try #require(message["method"]?.stringValue)
        let name = message["params"]?["name"]?.stringValue
        return (MCPTestRequest(body: bytes, method: [method], name: name.map { [$0] } ?? []), message)
    }

    @Test func serverDiscover() async throws {
        let (request, _) = try Self.request("server-discover.request.json")
        let response = await MCPTest.handle(request)
        #expect(response.status == .ok)
        #expect(response.json == (try MCPTest.json("examples/wire/server-discover.response.json")))
    }

    @Test func serverDiscoverReportsTheBuildVersion() async throws {
        let (request, _) = try Self.request("server-discover.request.json")
        let response = await MCPTest.handle(request, serverVersion: DeskhandServerModule.version)
        #expect(
            response.result?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["version"]
                == .string(DeskhandServerModule.version))
    }

    @Test(arguments: ToolCallExample.all)
    func toolsCall(_ example: ToolCallExample) async throws {
        let (request, message) = try Self.request("tools-call.\(example.name).request.json")
        let expected = try MCPTest.json("examples/wire/tools-call.\(example.name).response.json")
        let dispatcher = FakeDispatcher(example.reply)
        let response = await MCPTest.handle(request, dispatcher: dispatcher)

        let arguments = try #require(message["params"]?["arguments"]?.objectValue)
        #expect(dispatcher.calls == [try example.expectedCall(arguments)])
        #expect(dispatcher.principals == [MCPTestRequest.principal])
        #expect(response.status == .ok)
        #expect(response.json?.objectValue.map { Set($0.keys) } == expected.objectValue.map { Set($0.keys) })
        #expect(response.json?["jsonrpc"] == expected["jsonrpc"])
        #expect(response.id == expected["id"])
        let result = try #require(response.result)
        let expectedResult = try #require(expected["result"])
        #expect(result.objectValue.map { Set($0.keys) } == expectedResult.objectValue.map { Set($0.keys) })
        #expect(result["resultType"] == expectedResult["resultType"])
        #expect(result["isError"] == expectedResult["isError"])
        #expect(result["structuredContent"] == expectedResult["structuredContent"])

        guard case .array(let expectedContent)? = expectedResult["content"] else {
            Issue.record("example has no content")
            return
        }
        #expect(response.content.count == expectedContent.count)
        for (block, expectedBlock) in zip(response.content, expectedContent) {
            #expect(block.objectValue.map { Set($0.keys) } == expectedBlock.objectValue.map { Set($0.keys) })
            #expect(block["type"] == expectedBlock["type"])
            switch expectedBlock["type"] {
            case "text":
                let text = try #require(block["text"]?.stringValue)
                let expectedText = try #require(expectedBlock["text"]?.stringValue)
                #expect(try JSONValue(parsing: text) == JSONValue(parsing: expectedText))
                #expect(try JSONValue(parsing: text) == result["structuredContent"])
            case "image":
                #expect(block["mimeType"] == expectedBlock["mimeType"])
                #expect(block["data"] == .string(Data(WireResults.image).base64EncodedString()))
            default:
                Issue.record("unexpected block type \(String(describing: expectedBlock["type"]))")
            }
        }
    }

    @Test func toolsList() async throws {
        let (request, _) = try Self.request("tools-list.request.json")
        let response = await MCPTest.handle(request)
        #expect(response.status == .ok)
        #expect(response.id == 8)
        let result = try #require(response.result?.objectValue)
        #expect(Set(result.keys) == ["resultType", "tools", "ttlMs", "cacheScope"])
        #expect(result["resultType"] == "complete")
        #expect(result["ttlMs"] == 300_000)
        #expect(result["cacheScope"] == "private")
        guard case .array(let tools)? = result["tools"] else {
            Issue.record("tools is not an array")
            return
        }
        #expect(tools.map { $0["name"] } == ["status", "displays", "screenshot", "pointer", "keyboard", "lease"])
        for tool in tools {
            #expect(
                tool.objectValue.map { Set($0.keys) }
                    == ["name", "title", "description", "inputSchema", "outputSchema", "annotations"])
        }
    }

    struct ErrorExample: Sendable, CustomTestStringConvertible {
        let file: String
        let request: MCPTestRequest
        let status: HTTPResponseStatus

        var testDescription: String { file }
    }

    static let errorExamples: [ErrorExample] = [
        ErrorExample(
            file: "error.header-mismatch", request: .tool("keyboard", id: 6).with { $0.name = ["pointer"] },
            status: .badRequest),
        ErrorExample(file: "error.method-not-found", request: .call("resources/list", id: 15), status: .notFound),
        ErrorExample(
            file: "error.missing-protocol-version",
            request: .raw(#"{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{}}"#), status: .badRequest),
        ErrorExample(
            file: "error.missing-version-header",
            request: .call("tools/list", id: 13).with { $0.protocolVersion = [] }, status: .badRequest),
        ErrorExample(file: "error.unknown-tool", request: .tool("clipboard", id: 7), status: .ok),
        ErrorExample(
            file: "error.unsupported-protocol-version",
            request: .call("tools/list", id: 14).with { $0.protocolVersion = ["2025-06-18"] }, status: .badRequest),
    ]

    @Test(arguments: errorExamples)
    func jsonRPCError(_ example: ErrorExample) async throws {
        let response = await MCPTest.handle(example.request)
        #expect(response.status == example.status)
        #expect(response.json == (try MCPTest.json("examples/wire/\(example.file).response.json")))
    }
}
