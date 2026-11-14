import DeskhandCore
import Foundation
import NIOHTTP1
import Testing

@testable import DeskhandServer

/// `tools/call` after check 20: dispatch, refusals as `isError` results, and cancellation.
@Suite struct ToolCallTests {
    static let holder: JSONValue = "crew:inst-7f3a:desk-lunus"
    static let pointerArguments: JSONObject = [
        "holder_id": holder, "frame_id": "frm_Zk3vQ8sN1xT5bYc2Lw9RaA", "operation_id": "call_01HZX3M9Q3",
        "action": ["type": "click", "x": 1204, "y": 778],
    ]
    static let keyboardArguments: JSONObject = [
        "holder_id": holder, "frame_id": "frm_Zk3vQ8sN1xT5bYc2Lw9RaA", "operation_id": "call_01HZX3M9R1",
        "action": ["type": "type", "text": "hello"],
    ]

    static let effect = EffectResult(
        operationID: OperationID("call_01HZX3M9Q3")!, frameID: FrameID("frm_Zk3vQ8sN1xT5bYc2Lw9RaA")!,
        eventsPosted: 1, replayed: false,
        measured: Measured(
            frontmostApp: AppRef(bundleID: "com.apple.TextEdit", teamID: nil, name: "TextEdit"), targetApp: nil,
            windowTitle: nil, globalPoint: nil, measuredAt: Timestamp(millisecondsSinceEpoch: 1_794_668_539_730)),
        completedAt: Timestamp(millisecondsSinceEpoch: 1_794_668_539_781))

    struct Routing: Sendable, CustomTestStringConvertible {
        let tool: String
        let arguments: JSONObject?
        let reply: FakeDispatcher.Reply
        let expected: DispatchedCall

        var testDescription: String { tool }
    }

    static let routings: [Routing] = [
        Routing(
            tool: "status", arguments: nil, reply: .error(FakeDispatcher.unexpected),
            expected: .status(StatusArguments())),
        Routing(
            tool: "displays", arguments: [:],
            reply: .displays(DisplaysResult(displayConfigGeneration: DisplayConfigGeneration(1), displays: [])),
            expected: .displays),
        Routing(
            tool: "screenshot", arguments: ["holder_id": holder, "format": "png"],
            reply: .error(FakeDispatcher.unexpected),
            expected: .screenshot(try! ScreenshotArguments(arguments: ["holder_id": holder, "format": "png"]))),
        Routing(
            tool: "pointer", arguments: pointerArguments, reply: .effect(effect),
            expected: .pointer(try! PointerArguments(arguments: pointerArguments))),
        Routing(
            tool: "keyboard", arguments: keyboardArguments, reply: .effect(effect),
            expected: .keyboard(try! KeyboardArguments(arguments: keyboardArguments))),
        Routing(
            tool: "lease", arguments: ["op": "release", "holder_id": holder],
            reply: .lease(
                LeaseToolResult(result: LeaseResult(operation: .release, outcome: .released), lease: .notHeldByCaller)),
            expected: .lease(LeaseArguments(holderID: HolderID("crew:inst-7f3a:desk-lunus")!, command: .release))),
    ]

    @Test(arguments: routings)
    func eachToolReachesItsDispatcherMethod(_ routing: Routing) async {
        let dispatcher = FakeDispatcher(routing.reply)
        let response = await MCPTest.handle(.tool(routing.tool, routing.arguments), dispatcher: dispatcher)
        #expect(response.status == .ok)
        #expect(dispatcher.calls == [routing.expected])
        #expect(dispatcher.principals == [MCPTestRequest.principal])
        #expect(response.result?["resultType"] == "complete")
        #expect(response.isError != nil)
        #expect(response.contentText == response.structuredContent)
    }

    @Test func toolErrorIsAnIsErrorResultWithTheCode() async {
        let error = ToolError(.blocked(.disarmed), message: "deskhand is disarmed.", state: .disarmed)
        let response = await MCPTest.handle(.tool("displays"), dispatcher: FakeDispatcher(.error(error)))
        #expect(response.status == .ok)
        #expect(response.isError == true)
        #expect(response.structuredContent == error.jsonValue)
        #expect(response.structuredContent?["code"] == "disarmed")
        #expect(response.content.count == 1)
        #expect(response.content.first?["type"] == "text")
        #expect(response.contentText == error.jsonValue)
    }

    @Test func invalidArgumentsGoToTheDispatcherForTheStateAndRecord() async {
        let dispatcher = FakeDispatcher(.effect(Self.effect))
        var arguments = Self.pointerArguments
        arguments["action"] = ["type": "click", "x": 1204]
        let response = await MCPTest.handle(.tool("pointer", arguments), dispatcher: dispatcher)
        #expect(response.status == .ok)
        #expect(response.isError == true)
        #expect(response.structuredContent?["code"] == "invalid_argument")
        #expect(response.structuredContent?["details"]?["argument"] == "/action")
        #expect(response.structuredContent?["operation_id"] == "call_01HZX3M9Q3")
        guard case .refusal(.invalidArguments(let error), .pointer, let handles)? = dispatcher.calls.first else {
            Issue.record("expected one refusal, got \(dispatcher.calls)")
            return
        }
        #expect(dispatcher.calls.count == 1)
        #expect(error.pointer == JSONPointer(["action"]))
        #expect(handles.holderID == HolderID("crew:inst-7f3a:desk-lunus"))
        #expect(handles.operationID == OperationID("call_01HZX3M9Q3"))
    }

    @Test func unknownArgumentOfAToolWithoutArgumentsIsInvalidArgument() async {
        let dispatcher = FakeDispatcher()
        let response = await MCPTest.handle(.tool("displays", ["extra": 1]), dispatcher: dispatcher)
        #expect(response.isError == true)
        #expect(response.structuredContent?["code"] == "invalid_argument")
        #expect(dispatcher.calls.count == 1)
    }

    /// Contract 2.4: inside `params.arguments` a strict-JSON fault is `invalid_argument`, found before
    /// the schema, and the call is never dispatched.
    @Test(arguments: [
        (#"{"holder_id":"crew:a","holder_id":"crew:b"}"#, "/holder_id"),
        (#"{"action":{"type":"click","type":"move"}}"#, "/action/type"),
        (#"{"holder_id":"crew:\ud800"}"#, "/holder_id"),
        (#"{"a\udc00":1}"#, ""),
    ])
    func strictJSONFaultInsideArguments(_ arguments: String, _ pointer: String) async {
        let body =
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"pointer","arguments":"#
            + arguments + #","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        let dispatcher = FakeDispatcher(.effect(Self.effect))
        let response = await MCPTest.handle(.raw(body, method: "tools/call", name: "pointer"), dispatcher: dispatcher)
        #expect(response.status == .ok)
        #expect(response.id == 5)
        #expect(response.isError == true)
        #expect(response.structuredContent?["code"] == "invalid_argument")
        #expect(response.structuredContent?["details"]?["argument"] == .string(pointer))
        #expect(dispatcher.calls.count == 1)
        if case .refusal(.invalidArguments, .pointer, _)? = dispatcher.calls.first {
        } else {
            Issue.record("expected a refusal, got \(dispatcher.calls)")
        }
    }

    @Test func ambiguousHandleIsNotUsedForTheRecord() async {
        let body =
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"keyboard","arguments":"#
            + #"{"holder_id":"crew:a","operation_id":"op_1","operation_id":"op_2"},"#
            + #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        let dispatcher = FakeDispatcher()
        _ = await MCPTest.handle(.raw(body, method: "tools/call", name: "keyboard"), dispatcher: dispatcher)
        guard case .refusal(_, .keyboard, let handles)? = dispatcher.calls.first else {
            Issue.record("expected a refusal, got \(dispatcher.calls)")
            return
        }
        #expect(handles.holderID == HolderID("crew:a"))
        #expect(handles.operationID == nil)
    }

    @Test(arguments: [ImageEncoding.jpeg(.q75), .png])
    func screenshotPutsTheImageBeforeTheText(_ encoding: ImageEncoding) async {
        let image: [UInt8] = [0xFF, 0xD8, 0x00, 0x7F, 0x80, 0xFE]
        let result = ScreenshotResult(
            frameID: FrameID("frm_Zk3vQ8sN1xT5bYc2Lw9RaA")!, sha256: SHA256Hex(hex: String(repeating: "a", count: 64))!,
            displayID: DisplayID(1), displayConfigGeneration: DisplayConfigGeneration(1),
            captureRect: GlobalRect(x: 0, y: 0, width: 4, height: 2), sourcePixelSize: PixelSize(width: 8, height: 4),
            outputPixelSize: PixelSize(width: 8, height: 4), pointPixelScale: 2, downscale: 1, encoding: encoding,
            imageBytes: image.count, capturedAt: Timestamp(millisecondsSinceEpoch: 0), maxAgeMs: 60_000,
            pointerPosition: nil, frontmostApp: .undetermined)
        let dispatcher = FakeDispatcher(.screenshot(CapturedScreenshot(result: result, image: image)))
        let response = await MCPTest.handle(.tool("screenshot", ["holder_id": Self.holder]), dispatcher: dispatcher)
        #expect(response.isError == false)
        #expect(response.content.count == 2)
        let imageBlock: JSONValue = [
            "type": "image", "data": .string(Data(image).base64EncodedString()),
            "mimeType": .string(encoding.format.mimeType),
        ]
        #expect(response.content.first == imageBlock)
        #expect(response.content.last?["type"] == "text")
        #expect(response.contentText == result.jsonValue)
    }

    @Test func unencodableResultBecomesTheDispatchersInternalError() async {
        var effect = Self.effect
        effect.measured = Measured(
            frontmostApp: .undetermined, targetApp: nil, windowTitle: nil, globalPoint: GlobalPoint(x: .nan, y: 0),
            measuredAt: Timestamp(millisecondsSinceEpoch: 0))
        let dispatcher = FakeDispatcher(.effect(effect))
        let response = await MCPTest.handle(.tool("pointer", Self.pointerArguments), dispatcher: dispatcher)
        #expect(response.status == .ok)
        #expect(response.isError == true)
        #expect(response.structuredContent?["code"] == "internal_error")
        #expect(
            dispatcher.calls.last
                == .refusal(.unencodableResult, .pointer, EffectHandles(arguments: Self.pointerArguments)))
    }

    /// The listener cancels the request's task when the caller hangs up (contract 2.1); the call
    /// runs inside that task, so the dispatcher sees the cancellation.
    @Test(.timeLimit(.minutes(1)))
    func cancellingTheRequestTaskCancelsTheDispatch() async {
        let dispatcher = FakeDispatcher(.waitForCancellation)
        let handler = MCPHandler(dispatcher: dispatcher)
        let request = MCPTestRequest.tool("pointer", Self.pointerArguments).authenticated
        let task = Task { await handler.handle(request) }
        var started = dispatcher.started.makeAsyncIterator()
        _ = await started.next()
        task.cancel()
        _ = await task.value
        #expect(dispatcher.cancellations == 1)
    }
}
