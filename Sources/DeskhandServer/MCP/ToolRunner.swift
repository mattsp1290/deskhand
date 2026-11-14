import DeskhandCore
import Foundation

/// What one tool call produced, before it becomes a `tools/call` result.
enum ToolOutcome: Hashable, Sendable {
    case success(JSONValue)
    case screenshot(CapturedScreenshot)
    case failure(ToolError)
    /// A repeated effect call answered from its record: the stored `structuredContent`, an error
    /// unless the operation completed (contract 12.5).
    case replayed(JSONValue, isError: Bool)

    /// What an effect call answered with, or `nil` when it gets no answer: a call dropped before
    /// admission, whose connection already closed (contract 9.5), and every call once deskhand is
    /// stopping, the one the stop ended included, whose connection then closes unanswered
    /// (contract 15.2).
    init?(_ answer: EffectAnswer) {
        switch answer {
        case .completed(let result): self = .success(result.jsonValue)
        case .error(let error): self = .failure(error)
        case .replayed(let replay, let content): self = .replayed(content, isError: replay.isError)
        case .dropped: return nil
        }
    }

    /// The result of contract 3.3: `content` ends with the text of `structuredContent`, after the
    /// image of a successful `screenshot`; `isError` is set exactly for a tool error.
    func result() throws(NonFiniteNumberError) -> JSONValue {
        let structured: JSONValue
        var content: [JSONValue] = []
        switch self {
        case .success(let value), .replayed(let value, _): structured = value
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
        switch self {
        case .success, .screenshot: false
        case .failure: true
        case .replayed(_, let isError): isError
        }
    }
}

/// Validates a `tools/call`'s arguments with core's argument models and hands them to the
/// dispatcher, in the caller's task so that a hang-up cancels the call.
struct ToolRunner {
    let dispatcher: any ToolDispatcher
    let caller: ToolCaller

    /// `nil` when the call gets no answer (``ToolOutcome/init(_:)``).
    func run(_ tool: ToolName, _ arguments: ToolArguments) async -> ToolOutcome? {
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
            return try await perform(call, received: arguments.object)
        } catch {
            return .failure(error)
        }
    }

    func refusal(_ refusal: ToolRefusal, _ tool: ToolName, _ arguments: ToolArguments) async -> ToolError {
        await dispatcher.refusal(refusal, tool: tool, handles: arguments.handles, caller: caller)
    }

    private func perform(_ call: ToolCall, received: JSONObject) async throws(ToolError) -> ToolOutcome? {
        switch call {
        case .status(let arguments): .success(try await dispatcher.status(arguments, caller: caller).jsonValue)
        case .displays: .success(try await dispatcher.displays(caller: caller).jsonValue)
        case .screenshot(let arguments): .screenshot(try await dispatcher.screenshot(arguments, caller: caller))
        case .pointer(let arguments):
            ToolOutcome(await dispatcher.effect(.pointer(arguments), received: received, caller: caller))
        case .keyboard(let arguments):
            ToolOutcome(await dispatcher.effect(.keyboard(arguments), received: received, caller: caller))
        case .lease(let arguments): .success(try await dispatcher.lease(arguments, caller: caller).jsonValue)
        }
    }
}
