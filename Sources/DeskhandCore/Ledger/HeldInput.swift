/// A key or mouse button that deskhand presses and so might leave down.
public enum HeldInput: Hashable, Sendable, CustomStringConvertible {
    case key(Key)
    case modifier(Modifier)
    case button(MouseButton)

    public var description: String {
        switch self {
        case .key(let key): "key \(key.rawValue)"
        case .modifier(let modifier): "modifier \(modifier.rawValue)"
        case .button(let button): "button \(button.rawValue)"
        }
    }
}

/// The ledger file: `{"held":[{"modifier":"shift"},{"key":"a"}],"version":1}` in RFC 8785 form,
/// entries in press order.
enum HeldInputLedgerFormat {
    static let version = 1

    static func encode(_ entries: [HeldInput]) -> [UInt8] {
        let document: JSONValue = ["held": .array(entries.map(\.ledgerValue)), "version": JSONValue(version)]
        // Only strings and a small integer, so canonicalization has nothing non-finite to refuse.
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
        case .key(let key): ["key": .string(key.rawValue)]
        case .modifier(let modifier): ["modifier": .string(modifier.rawValue)]
        case .button(let button): ["button": .string(button.rawValue)]
        }
    }

    fileprivate init?(ledgerValue: JSONValue) {
        guard case .object(let members) = ledgerValue, members.count == 1, let (kind, value) = members.first,
            case .string(let name) = value
        else { return nil }
        let input: HeldInput? =
            switch kind {
            case "key": Key(rawValue: name).map(HeldInput.key)
            case "modifier": Modifier(rawValue: name).map(HeldInput.modifier)
            case "button": MouseButton(rawValue: name).map(HeldInput.button)
            default: nil
            }
        guard let input else { return nil }
        self = input
    }
}
