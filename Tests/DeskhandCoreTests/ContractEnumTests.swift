import DeskhandCore
import Testing

/// The Swift enums must list exactly the values of the schema enums, in the schema's order.
@Suite struct ContractEnumTests {
    private func schemaEnum(_ definition: String, in file: String = "defs.json") throws -> [String] {
        var node = try Fixtures.json(file)
        for name in definition.split(separator: "/") { node = try #require(node[String(name)]) }
        guard case .array(let values) = try #require(node["enum"]) else { throw SchemaShapeError() }
        return values.compactMap(\.stringValue)
    }

    private struct SchemaShapeError: Error {}

    @Test func enumsMatchDefsJSON() throws {
        #expect(try schemaEnum("$defs/state") == DeskhandState.allCases.map(\.rawValue))
        #expect(try schemaEnum("$defs/blocking_state") == BlockingState.allCases.map(\.rawValue))
        #expect(try schemaEnum("$defs/condition") == Condition.allCases.map(\.rawValue))
        #expect(try schemaEnum("$defs/error_code") == ToolErrorCode.allCases.map(\.rawValue))
        #expect(try schemaEnum("$defs/key") == Key.allCases.map(\.rawValue))
        #expect(try schemaEnum("$defs/modifier") == Modifier.allCases.map(\.rawValue))
        #expect(try schemaEnum("$defs/mouse_button") == MouseButton.allCases.map(\.rawValue))
        #expect(try schemaEnum("$defs/operation_status") == OperationStatus.allCases.map(\.rawValue))
        let reasons: [StaleFrameReason] = [
            .unknown, .displayChanged, .notLatest, .tooOld, .frontmostChanged, .pixelsChanged(pointIndex: 0),
        ]
        #expect(try schemaEnum("$defs/stale_frame_reason") == reasons.map(\.wireName))
    }

    @Test func enumsMatchToolSchemas() throws {
        let leaseResult = "$defs/lease_result/properties"
        #expect(
            try schemaEnum("\(leaseResult)/code", in: "tools/lease.output.json")
                == LeaseRefusal.Code.allCases.map(\.rawValue))
        #expect(
            try schemaEnum("\(leaseResult)/op", in: "tools/lease.output.json")
                == LeaseOperation.allCases.map(\.rawValue))
        let format = "$defs/screenshot_result/properties/format"
        #expect(try schemaEnum(format, in: "tools/screenshot.output.json") == ImageFormat.allCases.map(\.rawValue))
        #expect(ContractConstants.jpegQualitySteps.map(\.rawValue) == [85, 75, 65, 60])
    }

    @Test func statesOrderByPrecedence() {
        #expect(DeskhandState.allCases.sorted() == DeskhandState.allCases)
        #expect(DeskhandState.gated < .paused && DeskhandState.secureInput < .ok)
        #expect(BlockingState.allCases.map(\.state) == Array(DeskhandState.allCases.dropLast()))
        #expect(DeskhandState.ok.blocking == nil)
        #expect(BlockingState.allCases.filter(\.dropsLease) == [.gated, .paused, .disarmed])
    }

    @Test func activeStatesDeriveStateAndOrder() {
        let active = ActiveStates([.secureInput, .locked, .disarmed, .locked])
        #expect(active.current == .disarmed)
        #expect(active.inPrecedenceOrder == [.disarmed, .locked, .secureInput])
        #expect(ActiveStates.none.current == .ok)
        #expect(ActiveStates.none.inPrecedenceOrder.isEmpty)
    }

    @Test func everyBlockingStateIsAToolErrorCode() {
        for state in BlockingState.allCases {
            #expect(ToolErrorReason.blocked(state).code.rawValue == state.rawValue)
        }
    }

    @Test func jsonRPCErrorsCarryTheirHTTPStatus() {
        #expect(JSONRPCErrorCode.parseError.rawValue == -32_700 && JSONRPCErrorCode.parseError.httpStatus == 400)
        #expect(
            JSONRPCErrorCode.headerMismatch.rawValue == -32_020 && JSONRPCErrorCode.headerMismatch.httpStatus == 400)
        #expect(JSONRPCErrorCode.unsupportedProtocolVersion.rawValue == -32_022)
        #expect(JSONRPCErrorCode.methodNotFound.httpStatus == 200)
        #expect(JSONRPCErrorCode.invalidParams.httpStatus == 200)
    }

    @Test func timestampsAreUTCWithOptionalMilliseconds() {
        let cases: [(Int64, String)] = [
            (0, "1970-01-01T00:00:00Z"), (-1, "1969-12-31T23:59:59.999Z"),
            (951_868_800_000, "2000-03-01T00:00:00Z"), (1_709_251_199_999, "2024-02-29T23:59:59.999Z"),
            (1_794_668_539_730, "2026-11-14T15:02:19.730Z"), (1_794_663_602_000, "2026-11-14T13:40:02Z"),
        ]
        for (milliseconds, text) in cases {
            #expect(Timestamp(millisecondsSinceEpoch: milliseconds).description == text)
        }
    }
}
