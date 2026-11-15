import DeskhandCore
import Foundation

enum ToolOutcome: Hashable, Sendable {
    case success(JSONValue)
    case screenshot(CapturedScreenshot)
    case failure(ToolError)
    case replayed(JSONValue, isError: Bool)

    init?(_ answer: EffectAnswer) {
        switch answer {
        case .completed(let result): self = .success(result.jsonValue)
        case .error(let error): self = .failure(error)
        case .replayed(let replay, let content): self = .replayed(content, isError: replay.isError)
        case .dropped: return nil
        }
    }

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

struct ToolRunner {
    let dispatcher: any ToolDispatcher
    let caller: ToolCaller

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
