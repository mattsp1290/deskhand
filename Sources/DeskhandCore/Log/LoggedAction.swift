/// What an effect call asked for, as the action log records it. A pointer action is kept whole: it
/// holds only frame pixels, buttons and modifiers. A keyboard action has no member that can hold
/// text: typed text is reduced to its length, and a character key pressed as typing loses its name.
public enum LoggedAction: Hashable, Sendable, JSONRepresentable {
    case pointer(PointerAction)
    case keyboard(LoggedKeyboardAction)

    public var tool: ToolName {
        switch self {
        case .pointer: .pointer
        case .keyboard: .keyboard
        }
    }

    /// The same members as the call's `action` argument, with every default written out.
    public var jsonValue: JSONValue {
        switch self {
        case .pointer(let action): action.loggedJSON
        case .keyboard(let action): action.jsonValue
        }
    }

    static func decode(tool: ToolName) -> ValueDecoder<LoggedAction> {
        { value, path throws(ArgumentError) in
            switch tool {
            case .pointer: return .pointer(try PointerAction.decode(value, path))
            case .keyboard: return .keyboard(try LoggedKeyboardAction.decode(value, path))
            case .status, .displays, .screenshot, .lease:
                throw ArgumentError(at: path, "\(tool.rawValue) is not an effect tool")
            }
        }
    }
}

public enum LoggedKeyboardAction: Hashable, Sendable, JSONRepresentable {
    /// `type`, as the number of Unicode code points in the text.
    case type(textLength: Int)
    case press(LoggedKeyPress)

    public init(_ action: KeyboardAction) {
        switch action {
        case .type(let text): self = .type(textLength: text.unicodeScalars.count)
        case .press(let press): self = .press(LoggedKeyPress(press))
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .type(let length): ["type": "type", "text_length": JSONValue(length)]
        case .press(let press):
            [
                "type": "press", "key": press.key.jsonValue, "modifiers": Modifier.jsonArray(press.modifiers),
                "hold_ms": JSONValue(press.holdMs),
            ]
        }
    }

    static func decode(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> LoggedKeyboardAction {
        switch value["type"] {
        case "type":
            let reader = try ObjectReader(value, at: path, allowing: ["type", "text_length"])
            return .type(
                textLength: try reader.required(
                    "text_length", Decode.integer(1...ContractConstants.keyboardMaxTextLength)))
        case "press":
            let reader = try ObjectReader(value, at: path, allowing: ["type", "key", "modifiers", "hold_ms"])
            let key = try reader.required("key") { value, path throws(ArgumentError) -> LoggedKey in
                value == .null ? .withheld : .named(try Decode.oneOf(Key.self)(value, path))
            }
            let modifiers = try reader.required("modifiers", Decode.modifiers)
            let holdMs = try reader.required("hold_ms", Decode.integer(ContractConstants.keyHoldMsRange))
            guard let press = LoggedKeyPress(key: key, modifiers: modifiers, holdMs: holdMs) else {
                throw ArgumentError(
                    at: path.appending("key"), "is null exactly for a character key pressed without command or control")
            }
            return .press(press)
        default:
            throw ArgumentError(at: path.appending("type"), "must be type or press")
        }
    }
}

/// A `keyboard` `press` as logged. Pressing character keys one by one is typing, so a character key
/// is named only when command or control turn it into a shortcut.
public struct LoggedKeyPress: Hashable, Sendable {
    public let key: LoggedKey
    public let modifiers: Set<Modifier>
    public let holdMs: Int

    public init(_ press: KeyPress) {
        key = Self.namesKey(press.key, press.modifiers) ? .named(press.key) : .withheld
        modifiers = press.modifiers
        holdMs = press.holdMs
    }

    /// `nil` when `key` breaks the naming rule, so a decoded entry has the one form ``init(_:)`` builds.
    init?(key: LoggedKey, modifiers: Set<Modifier>, holdMs: Int) {
        let named: Bool
        switch key {
        case .named(let name):
            guard Self.namesKey(name, modifiers) else { return nil }
            named = true
        case .withheld: named = false
        }
        guard named || !modifiers.isShortcut else { return nil }
        self.key = key
        self.modifiers = modifiers
        self.holdMs = holdMs
    }

    private static func namesKey(_ key: Key, _ modifiers: Set<Modifier>) -> Bool {
        !key.producesCharacter || modifiers.isShortcut
    }
}

public enum LoggedKey: Hashable, Sendable, JSONRepresentable {
    case named(Key)
    /// A character key pressed without command or control, written as `null`.
    case withheld

    public var jsonValue: JSONValue {
        switch self {
        case .named(let key): .string(key.rawValue)
        case .withheld: .null
        }
    }
}

extension Key {
    /// Letters, digits, punctuation and space: the keys whose press inserts a character.
    fileprivate var producesCharacter: Bool { self == .space || rawValue.unicodeScalars.count == 1 }
}

extension Set<Modifier> {
    fileprivate var isShortcut: Bool { contains(.command) || contains(.control) }
}

extension Modifier {
    fileprivate static func jsonArray(_ modifiers: Set<Modifier>) -> JSONValue {
        .array(modifiers.sorted().map { .string($0.rawValue) })
    }
}

extension PointerAction {
    fileprivate var loggedJSON: JSONValue {
        switch self {
        case .move(let point): ["type": "move", "x": JSONValue(point.x), "y": JSONValue(point.y)]
        case .click(let click):
            [
                "type": "click", "x": JSONValue(click.point.x), "y": JSONValue(click.point.y),
                "button": .string(click.button.rawValue), "count": JSONValue(click.count),
                "modifiers": Modifier.jsonArray(click.modifiers),
            ]
        case .drag(let drag):
            [
                "type": "drag", "path": .array(drag.path.map(\.jsonValue)), "button": .string(drag.button.rawValue),
                "modifiers": Modifier.jsonArray(drag.modifiers), "duration_ms": JSONValue(drag.durationMs),
            ]
        case .scroll(let scroll):
            [
                "type": "scroll", "x": JSONValue(scroll.point.x), "y": JSONValue(scroll.point.y),
                "dx": JSONValue(scroll.dx), "dy": JSONValue(scroll.dy),
                "modifiers": Modifier.jsonArray(scroll.modifiers),
            ]
        }
    }
}
