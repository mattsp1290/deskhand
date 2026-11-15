public typealias KeyboardArguments = EffectArguments<KeyboardAction>

extension EffectArguments where Action == KeyboardAction {
    public init(arguments: JSONObject) throws(ArgumentError) {
        try self.init(arguments: arguments, action: KeyboardAction.decode)
    }
}

/// A key name (`defs.json#/$defs/key`). A character key names the key that produces that character
/// unshifted in the active layout.
public enum Key: String, CaseIterable, Sendable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit0 = "0"
    case digit1 = "1"
    case digit2 = "2"
    case digit3 = "3"
    case digit4 = "4"
    case digit5 = "5"
    case digit6 = "6"
    case digit7 = "7"
    case digit8 = "8"
    case digit9 = "9"
    case minus = "-"
    case equal = "="
    case leftBracket = "["
    case rightBracket = "]"
    case backslash = "\\"
    case semicolon = ";"
    case quote = "'"
    case comma = ","
    case period = "."
    case slash = "/"
    case grave = "`"
    case `return`, tab, space, delete
    case forwardDelete = "forward_delete"
    case escape, up, down, left, right, home, end
    case pageUp = "page_up"
    case pageDown = "page_down"
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

/// A `keyboard` `press`: modifiers down, key down, `holdMs`, key up, modifiers up.
public struct KeyPress: Hashable, Sendable {
    public let key: Key
    public let modifiers: Set<Modifier>
    public let holdMs: Int

    /// The chord as `details.shortcut` spells it: modifiers in press order, then the key, joined by `+`.
    public var shortcut: String { Chord(self).shortcut }
}

/// A `keyboard` action (contract 6.5), defaults applied.
public enum KeyboardAction: Hashable, Sendable {
    /// 1 to 1024 code points with no C0 or C1 control, U+2028 or U+2029.
    case type(String)
    case press(KeyPress)

    static func decode(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> KeyboardAction {
        switch value["type"] {
        case "type":
            let reader = try ObjectReader(value, at: path, allowing: ["type", "text"])
            return .type(try reader.required("text", text))
        case "press":
            let reader = try ObjectReader(value, at: path, allowing: ["type", "key", "modifiers", "hold_ms"])
            return .press(
                KeyPress(
                    key: try reader.required("key", Decode.oneOf(Key.self)),
                    modifiers: try reader.optional("modifiers", Decode.modifiers) ?? [],
                    holdMs: try reader.optional("hold_ms", Decode.integer(ContractConstants.keyHoldMsRange)) ?? 0))
        case .string?:
            throw ArgumentError(at: path.appending("type"), "must be type or press")
        default:
            throw ArgumentError(at: path, "needs a string 'type'")
        }
    }

    private static func text(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> String {
        let text = try Decode.string(value, path)
        let scalars = text.unicodeScalars
        guard (1...ContractConstants.keyboardMaxTextLength).contains(scalars.count) else {
            throw ArgumentError(at: path, "must be 1 to \(ContractConstants.keyboardMaxTextLength) code points")
        }
        let forbidden: (Unicode.Scalar) -> Bool = {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || $0 == "\u{2028}" || $0 == "\u{2029}"
        }
        guard !scalars.contains(where: forbidden) else {
            throw ArgumentError(
                at: path, "must not contain control characters, U+2028 or U+2029; send return and tab as press")
        }
        return text
    }
}
