import DeskhandCore
import DeskhandTestSupport
import Testing

/// Builders for action log tests. Every value is fake.
enum LogSamples {
    static let time = Timestamp(millisecondsSinceEpoch: 1_794_657_600_250)
    static let node = NodeAddress("10.0.0.21")!
    static let principal = Principal(certificateSubject: "CN=crew-executor,O=birb")
    static let frameSHA256 = SHA256Hex(hashing: Array("fake image".utf8))
    static let textEdit = AppRef(bundleID: "com.apple.TextEdit", teamID: nil, name: "TextEdit")
    static let frameID = "frm_AAAAAAAAAAAAAAAAAAAAAA"

    static func handles(operation: String = "op-1") -> JSONObject {
        ["holder_id": "crew-1", "frame_id": .string(frameID), "operation_id": .string(operation)]
    }

    static func keyboardArguments(_ action: JSONValue, operation: String = "op-1") throws -> KeyboardArguments {
        var arguments = handles(operation: operation)
        arguments["action"] = action
        return try KeyboardArguments(arguments: arguments)
    }

    static func pointerArguments(_ action: JSONValue, operation: String = "op-1") throws -> PointerArguments {
        var arguments = handles(operation: operation)
        arguments["action"] = action
        return try PointerArguments(arguments: arguments)
    }

    static func intent(keyboard action: JSONValue, operation: String = "op-1") throws -> ActionLogIntent {
        ActionLogIntent(
            time: time, nodeAddress: node, principal: principal,
            arguments: try keyboardArguments(action, operation: operation), frameSHA256: frameSHA256,
            frontmostApp: textEdit)
    }

    static func intent(pointer action: JSONValue, operation: String = "op-1") throws -> ActionLogIntent {
        ActionLogIntent(
            time: time, nodeAddress: node, principal: principal,
            arguments: try pointerArguments(action, operation: operation), frameSHA256: frameSHA256,
            frontmostApp: textEdit)
    }

    static func typing(_ text: String) -> JSONValue { ["type": "type", "text": .string(text)] }

    static let preview = AppRef(bundleID: "com.apple.Preview", teamID: nil, name: "Preview")

    /// A last look with TextEdit in front and Preview as the target. The title must never be logged.
    static let measured = Measured(
        frontmostApp: textEdit, targetApp: preview, windowTitle: "secret title", globalPoint: nil,
        measuredAt: time.adding(milliseconds: 20))

    /// An outcome line can only come from a committed intent, so this commits one first.
    static func outcomeLine(
        _ outcome: ActionOutcome, intent: ActionLogIntent, measured: Measured? = measured
    ) async throws -> ActionLogLine {
        let log = InMemoryActionLog()
        let receipt = try await log.commitIntent(intent)
        try await log.commitOutcome(receipt, outcome, measured: measured, now: time.adding(milliseconds: 1500))
        return try #require(await log.lines.last)
    }

    static func text(_ line: ActionLogLine) -> String { String(decoding: line.bytes, as: UTF8.self) }
}
