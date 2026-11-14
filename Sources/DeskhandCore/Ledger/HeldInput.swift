/// A virtual key code as the platform layer posted it (on macOS, a `CGKeyCode`). Core never
/// interprets it. The layer that turned a key name or a character into a code under the layout
/// active at the press records that code, and releases by the same code whatever the layout is by
/// then.
public struct PostedKeyCode: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public var description: String { "0x" + String(rawValue, radix: 16) }
}

/// Something deskhand pressed and so might have left down, recorded as it was posted, so that its
/// release needs nothing resolved again.
public enum HeldInput: Hashable, Sendable, CustomStringConvertible {
    /// A key-down posted with this code: a key of `press`, or the key that carried a character of
    /// `type`.
    case key(PostedKeyCode)
    /// A modifier put down with this code (on macOS, a flags-changed event rather than a key-down).
    case modifier(PostedKeyCode)
    case button(MouseButton)

    public var description: String {
        switch self {
        case .key(let code): "key \(code)"
        case .modifier(let code): "modifier \(code)"
        case .button(let button): "button \(button.rawValue)"
        }
    }
}

/// The ledger file: `{"held":[{"modifier":56},{"key":0},{"button":"left"}],"version":1}` in RFC 8785
/// form, entries in press order.
enum HeldInputLedgerFormat {
    static let version = 1

    static func encode(_ entries: [HeldInput]) -> [UInt8] {
        let document: JSONValue = ["held": .array(entries.map(\.ledgerValue)), "version": JSONValue(version)]
        // Only strings and small integers, so canonicalization has nothing non-finite to refuse.
        return try! document.canonicalBytes()
    }

    static func decode(_ bytes: [UInt8]) throws(HeldInputLedgerError) -> [HeldInput] {
        let document: JSONValue
        do { document = try JSONValue(parsing: bytes) } catch { throw .corrupt("not JSON: \(error)") }
        guard case .object(let members) = document, Set(members.keys) == ["held", "version"] else {
            throw .corrupt("needs exactly the members held and version")
        }
        guard members["version"] == JSONValue(version) else { throw .corrupt("unknown version") }
        guard case .array(let items)? = members["held"] else { throw .corrupt("held is not an array") }
        var entries: [HeldInput] = []
        for item in items {
            guard let input = HeldInput(ledgerValue: item) else { throw .corrupt("unknown entry \(item)") }
            guard !entries.contains(input) else { throw .corrupt("duplicate entry \(input)") }
            entries.append(input)
        }
        return entries
    }
}

extension HeldInput {
    fileprivate var ledgerValue: JSONValue {
        switch self {
        case .key(let code): ["key": JSONValue(code.rawValue)]
        case .modifier(let code): ["modifier": JSONValue(code.rawValue)]
        case .button(let button): ["button": .string(button.rawValue)]
        }
    }

    fileprivate init?(ledgerValue: JSONValue) {
        guard case .object(let members) = ledgerValue, members.count == 1, let (kind, value) = members.first else {
            return nil
        }
        let input: HeldInput? =
            switch (kind, value) {
            case ("key", .number(let number)): UInt16(exactly: number).map { .key(PostedKeyCode($0)) }
            case ("modifier", .number(let number)): UInt16(exactly: number).map { .modifier(PostedKeyCode($0)) }
            case ("button", .string(let name)): MouseButton(rawValue: name).map(HeldInput.button)
            default: nil
            }
        guard let input else { return nil }
        self = input
    }
}
