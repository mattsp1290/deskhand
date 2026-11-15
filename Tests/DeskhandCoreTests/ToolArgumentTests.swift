import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct ToolArgumentTests {
    static let invalidInputPointers: [String: String] = [
        "displays.input.unexpected-argument.json": "",
        "keyboard.input.hold-too-long.json": "/action/hold_ms",
        "keyboard.input.holder-trailing-newline.json": "/holder_id",
        "keyboard.input.missing-holder.json": "",
        "keyboard.input.permitted-app-trailing-newline.json": "/permitted_apps/0",
        "keyboard.input.press-with-text.json": "/action",
        "keyboard.input.text-empty.json": "/action/text",
        "keyboard.input.text-too-long.json": "/action/text",
        "keyboard.input.text-trailing-nel.json": "/action/text",
        "keyboard.input.text-trailing-newline.json": "/action/text",
        "keyboard.input.text-with-line-separator.json": "/action/text",
        "keyboard.input.text-with-newline.json": "/action/text",
        "keyboard.input.text-with-tab.json": "/action/text",
        "keyboard.input.type-unknown-member.json": "/action",
        "keyboard.input.unknown-modifier.json": "/action/modifiers/0",
        "keyboard.input.uppercase-key.json": "/action/key",
        "pointer.input.bad-operation-id.json": "/operation_id",
        "pointer.input.click-count-4.json": "/action/count",
        "pointer.input.click-fractional.json": "/action/x",
        "pointer.input.click-unknown-member.json": "/action",
        "pointer.input.drag-33-points.json": "/action/path",
        "pointer.input.drag-duration-too-long.json": "/action/duration_ms",
        "pointer.input.drag-duration-too-short.json": "/action/duration_ms",
        "pointer.input.drag-one-point.json": "/action/path",
        "pointer.input.drag-unknown-member.json": "/action",
        "pointer.input.duplicate-modifier.json": "/action/modifiers/1",
        "pointer.input.frame-id-trailing-newline.json": "/frame_id",
        "pointer.input.missing-frame-id.json": "",
        "pointer.input.missing-operation-id.json": "",
        "pointer.input.move-with-button.json": "/action",
        "pointer.input.operation-id-trailing-newline.json": "/operation_id",
        "pointer.input.permitted-apps-duplicate.json": "/permitted_apps/1",
        "pointer.input.scroll-dx-too-large.json": "/action/dx",
        "pointer.input.scroll-dx-too-small.json": "/action/dx",
        "pointer.input.scroll-dy-too-large.json": "/action/dy",
        "pointer.input.scroll-dy-too-small.json": "/action/dy",
        "pointer.input.scroll-no-delta.json": "/action",
        "pointer.input.scroll-unknown-member.json": "/action",
        "pointer.input.scroll-zero.json": "/action",
        "pointer.input.unknown-action.json": "/action/type",
        "screenshot.input.empty-region.json": "/region/width",
        "screenshot.input.max-long-edge-too-large.json": "/max_long_edge",
        "screenshot.input.max-long-edge-too-small.json": "/max_long_edge",
        "screenshot.input.missing-holder.json": "",
        "screenshot.input.unknown-format.json": "/format",
        "status.input.holder-with-space.json": "/holder_id",
        "status.input.lease-argument.json": "",
        "status.input.operation-unknown-member.json": "/operation",
        "status.input.operation-without-holder.json": "/operation",
        "lease.input.missing-holder.json": "",
        "lease.input.missing-op.json": "",
        "lease.input.nested-under-lease.json": "",
        "lease.input.ttl-fractional.json": "/ttl_ms",
        "lease.input.ttl-too-long.json": "/ttl_ms",
        "lease.input.ttl-too-short.json": "/ttl_ms",
        "lease.input.unknown-member.json": "",
        "lease.input.unknown-op.json": "/op",
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

        let renew = try decode(.lease, Fixtures.json("examples/lease.input.renew-default-ttl.json"))
        #expect(
            renew
                == .lease(
                    LeaseArguments(holderID: HolderID("crew:inst-7f3a:desk-lunus")!, command: .renew(ttlMs: 30_000))))
        let release = try decode(.lease, Fixtures.json("examples/lease.input.release.json"))
        #expect(release == .lease(LeaseArguments(holderID: HolderID("crew:inst-7f3a:desk-lunus")!, command: .release)))

        let lookup = try decode(.status, Fixtures.json("examples/status.input.operation-lookup.json"))
        let holder = HolderID("crew:inst-7f3a:desk-lunus")!
        #expect(
            lookup
                == .status(
                    StatusArguments(
                        holderID: holder,
                        operation: OperationQuery(holderID: holder, operationID: OperationID("call_01HZX3M9Q3")!))))
        #expect(try decode(.status, [:]) == .status(StatusArguments()))

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

    @Test func releaseRefusesTTL() throws {
        let error = try #require(throws: ArgumentError.self) {
            try decode(.lease, ["op": "release", "holder_id": "h", "ttl_ms": 30_000])
        }
        #expect(error.pointer.description == "/ttl_ms")
    }

    /// Enumerated values match by Unicode scalars, as the schema's `enum` does: U+037E GREEK QUESTION
    /// MARK and U+1FEF GREEK VARIA canonically equal `;` and `` ` ``, and are not keys.
    @Test(arguments: ["\u{037E}", "\u{1FEF}"])
    func enumeratedValuesMatchByScalars(_ key: String) {
        let arguments: JSONValue = [
            "holder_id": "h", "frame_id": "f", "operation_id": "o", "action": ["type": "press", "key": .string(key)],
        ]
        #expect(throws: ArgumentError.self) { try decode(.keyboard, arguments) }
    }

    @Test func memberNamesMatchByScalars() {
        // U+212A KELVIN SIGN canonically equals K; a member spelled with it is unknown, not `K`.
        #expect(throws: ArgumentError.self) {
            try decode(.lease, ["op": "acquire", "holder_id": "h", "\u{212A}": 1])
        }
    }

    @Test func pointerEscapesTokens() {
        #expect(JSONPointer.root.appending("a/b").appending("m~n").appending(0).description == "/a~1b/m~0n/0")
    }
}
