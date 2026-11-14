import DeskhandCore
import Testing

@Suite struct ToolArgumentTests {
    /// Every invalid input example and the `details.argument` pointer deskhand answers it with.
    static let invalidInputPointers: [String: String] = [
        "displays.input.unexpected-argument.json": "",
        "keyboard.input.holder-trailing-newline.json": "/holder_id",
        "keyboard.input.missing-holder.json": "",
        "keyboard.input.press-with-text.json": "/action",
        "keyboard.input.text-empty.json": "/action/text",
        "keyboard.input.text-too-long.json": "/action/text",
        "keyboard.input.text-trailing-nel.json": "/action/text",
        "keyboard.input.text-trailing-newline.json": "/action/text",
        "keyboard.input.text-with-line-separator.json": "/action/text",
        "keyboard.input.text-with-newline.json": "/action/text",
        "keyboard.input.text-with-tab.json": "/action/text",
        "keyboard.input.unknown-modifier.json": "/action/modifiers/0",
        "keyboard.input.uppercase-key.json": "/action/key",
        "pointer.input.bad-operation-id.json": "/operation_id",
        "pointer.input.click-count-4.json": "/action/count",
        "pointer.input.click-fractional.json": "/action/x",
        "pointer.input.drag-one-point.json": "/action/path",
        "pointer.input.duplicate-modifier.json": "/action/modifiers/1",
        "pointer.input.frame-id-trailing-newline.json": "/frame_id",
        "pointer.input.missing-frame-id.json": "",
        "pointer.input.missing-operation-id.json": "",
        "pointer.input.move-with-button.json": "/action",
        "pointer.input.operation-id-trailing-newline.json": "/operation_id",
        "pointer.input.permitted-apps-duplicate.json": "/permitted_apps/1",
        "pointer.input.scroll-no-delta.json": "/action",
        "pointer.input.scroll-zero.json": "/action",
        "pointer.input.unknown-action.json": "/action/type",
        "screenshot.input.empty-region.json": "/region/width",
        "screenshot.input.max-long-edge-too-large.json": "/max_long_edge",
        "screenshot.input.max-long-edge-too-small.json": "/max_long_edge",
        "screenshot.input.missing-holder.json": "",
        "screenshot.input.unknown-format.json": "/format",
        "status.input.lease-without-holder.json": "/lease",
        "status.input.ttl-too-long.json": "/lease/ttl_ms",
        "status.input.unknown-op.json": "/lease/op",
    ]

    private func decode(_ tool: ToolName, _ arguments: JSONValue) throws -> ToolCall {
        try ToolCall(tool: tool, arguments: #require(arguments.objectValue))
    }

    @Test(arguments: Fixtures.names(in: "examples", kind: ".input."))
    func validInputExampleDecodes(name: String) throws {
        let tool = try #require(Fixtures.tool(of: name))
        let call = try decode(tool, Fixtures.json("examples/\(name)"))
        #expect(call.tool == tool)
    }

    @Test(arguments: Fixtures.names(in: "examples/invalid", kind: ".input."))
    func invalidInputExampleIsRefused(name: String) throws {
        let tool = try #require(Fixtures.tool(of: name))
        let expected = try #require(Self.invalidInputPointers[name], "no expected pointer for \(name)")
        let arguments = try Fixtures.json("examples/invalid/\(name)")
        let error = try #require(throws: ArgumentError.self) { try decode(tool, arguments) }
        #expect(error.pointer.description == expected, "\(error.message)")
    }

    @Test func everyInvalidInputExampleHasAnExpectation() {
        #expect(Set(Fixtures.names(in: "examples/invalid", kind: ".input.")) == Set(Self.invalidInputPointers.keys))
    }

    @Test(arguments: Fixtures.names(in: "examples/wire", kind: "tools-call.").filter { $0.hasSuffix(".request.json") })
    func wireRequestArgumentsDecode(name: String) throws {
        let params = try #require(Fixtures.json("examples/wire/\(name)")["params"])
        let tool = try #require(params["name"]?.stringValue.flatMap(ToolName.init))
        _ = try decode(tool, #require(params["arguments"]))
    }

    @Test func appliesDefaults() throws {
        let click = try decode(.pointer, Fixtures.json("examples/pointer.input.click.json"))
        guard case .pointer(let arguments) = click, case .click(let action) = arguments.action else {
            Issue.record("expected a click")
            return
        }
        #expect(action.point == FramePoint(x: 1204, y: 778))
        #expect(action.button == .left && action.count == 1 && action.modifiers.isEmpty)
        #expect(arguments.permittedApps == nil)

        let release = try decode(.status, Fixtures.json("examples/status.input.release.json"))
        guard case .status(let status) = release else {
            Issue.record("expected status")
            return
        }
        #expect(status.lease?.ttlMs == 30_000)
        #expect(status.lease?.operation == .release)

        let screenshot = try decode(.screenshot, Fixtures.json("examples/screenshot.input.default.json"))
        guard case .screenshot(let shot) = screenshot else {
            Issue.record("expected screenshot")
            return
        }
        #expect(shot.format == .jpeg && shot.maxLongEdge == 2576 && shot.displayID == nil && shot.region == nil)
    }

    @Test func integerMayHaveAZeroFraction() throws {
        let call = try decode(.screenshot, ["holder_id": "h", "max_long_edge": 1568.0, "display_id": 4_294_967_295])
        guard case .screenshot(let shot) = call else {
            Issue.record("expected screenshot")
            return
        }
        #expect(shot.maxLongEdge == 1568)
        #expect(shot.displayID == DisplayID(UInt32.max))
    }

    @Test func pressDecodesAChordInPressOrder() throws {
        let call = try decode(.keyboard, Fixtures.json("examples/keyboard.input.press-chord.json"))
        guard case .keyboard(let arguments) = call, case .press(let press) = arguments.action else {
            Issue.record("expected a press")
            return
        }
        #expect(press.shortcut == "shift+command+s")
        #expect(arguments.permittedApps == [BundleID("com.apple.TextEdit")!])
    }

    @Test func actionWithoutATypeNamesTheAction() throws {
        let arguments: JSONValue = ["holder_id": "h", "frame_id": "f", "operation_id": "o", "action": ["x": 1]]
        let error = try #require(throws: ArgumentError.self) { try decode(.pointer, arguments) }
        #expect(error.pointer.description == "/action")
    }

    @Test func handlesAreReadEvenWhenOtherArgumentsAreInvalid() {
        let handles = EffectHandles(arguments: ["holder_id": "h", "operation_id": "o", "frame_id": 7])
        #expect(handles.holderID == HolderID("h") && handles.operationID == OperationID("o"))
        let malformed = EffectHandles(arguments: ["holder_id": "h\n", "operation_id": 1])
        #expect(malformed.holderID == nil && malformed.operationID == nil)
    }

    @Test func pointerEscapesTokens() {
        #expect(JSONPointer.root.appending("a/b").appending("m~n").appending(0).description == "/a~1b/m~0n/0")
    }
}
