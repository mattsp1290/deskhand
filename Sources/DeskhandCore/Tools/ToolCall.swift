/// A `tools/call` whose arguments passed validation, ready for dispatch.
public enum ToolCall: Hashable, Sendable {
    case status(StatusArguments)
    case displays
    case screenshot(ScreenshotArguments)
    case pointer(PointerArguments)
    case keyboard(KeyboardArguments)

    /// `arguments` is `{}` when the request omitted it (contract 3.3).
    public init(tool: ToolName, arguments: JSONObject) throws(ArgumentError) {
        switch tool {
        case .status: self = .status(try StatusArguments(arguments: arguments))
        case .displays:
            _ = try ObjectReader(.object(arguments), at: .root, allowing: [])
            self = .displays
        case .screenshot: self = .screenshot(try ScreenshotArguments(arguments: arguments))
        case .pointer: self = .pointer(try PointerArguments(arguments: arguments))
        case .keyboard: self = .keyboard(try KeyboardArguments(arguments: arguments))
        }
    }

    public var tool: ToolName {
        switch self {
        case .status: .status
        case .displays: .displays
        case .screenshot: .screenshot
        case .pointer: .pointer
        case .keyboard: .keyboard
        }
    }
}
