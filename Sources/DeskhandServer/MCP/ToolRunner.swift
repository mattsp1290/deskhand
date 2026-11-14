import DeskhandCore
import Foundation

/// What one tool call produced, before it becomes a `tools/call` result.
enum ToolOutcome: Hashable, Sendable {
    case success(JSONValue)
    case screenshot(CapturedScreenshot)
    case failure(ToolError)

    /// The result of contract 3.3: `content` ends with the text of `structuredContent`, after the
    /// image of a successful `screenshot`; `isError` is set exactly for a tool error.
    func result() throws(NonFiniteNumberError) -> JSONValue {
        let structured: JSONValue
        var content: [JSONValue] = []
        switch self {
        case .success(let value): structured = value
        case .failure(let error): structured = error.jsonValue
        case .screenshot(let captured):
            structured = captured.result.jsonValue
            content.append([
                "type": "image", "data": .string(Data(captured.image).base64EncodedString()),
                "mimeType": .string(captured.result.encoding.format.mimeType),
            ])
        }
        content.append(["type": "text", "text": .string(try structured.canonicalString())])
        return [
            "resultType": "complete", "content": .array(content), "structuredContent": structured,
            "isError": .bool(isError),
        ]
    }

    var isError: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// Validates a `tools/call`'s arguments with core's argument models and hands them to the
/// dispatcher, in the caller's task so that a hang-up cancels the call.
struct ToolRunner {
    let dispatcher: any ToolDispatcher
    let principal: Principal

    func run(_ tool: ToolName, _ arguments: ToolArguments) async -> ToolOutcome {
        if let fault = arguments.strictFault {
            return .failure(await refusal(.invalidArguments(fault), tool, arguments))
        }
        let call: ToolCall
        do {
            call = try ToolCall(tool: tool, arguments: arguments.object)
        } catch {
            return .failure(await refusal(.invalidArguments(error), tool, arguments))
        }
        do {
            return try await perform(call)
        } catch {
            return .failure(error)
        }
    }

    func refusal(_ refusal: ToolRefusal, _ tool: ToolName, _ arguments: ToolArguments) async -> ToolError {
        await dispatcher.refusal(refusal, tool: tool, handles: arguments.handles, principal: principal)
    }

    private func perform(_ call: ToolCall) async throws(ToolError) -> ToolOutcome {
        switch call {
        case .status(let arguments): .success(try await dispatcher.status(arguments, principal: principal).jsonValue)
        case .displays: .success(try await dispatcher.displays(principal: principal).jsonValue)
        case .screenshot(let arguments): .screenshot(try await dispatcher.screenshot(arguments, principal: principal))
        case .pointer(let arguments): .success(try await dispatcher.pointer(arguments, principal: principal).jsonValue)
        case .keyboard(let arguments):
            .success(try await dispatcher.keyboard(arguments, principal: principal).jsonValue)
        case .lease(let arguments): .success(try await dispatcher.lease(arguments, principal: principal).jsonValue)
        }
    }
}
