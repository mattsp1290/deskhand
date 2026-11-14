/// An I-JSON (RFC 7493) value: what deskhand parses from a request and serializes into a response.
///
/// Numbers are IEEE 754 doubles because RFC 8785 canonicalization is defined over doubles. Swift
/// compares strings by canonical equivalence, so `==` on two values treats differently normalized
/// strings as equal, and one object cannot hold two member names that differ only that way (the
/// parser refuses such an object). Serialization keeps the original code points, so the canonical
/// bytes and the request digest never conflate them, and every name or enumerated value deskhand
/// reads from a caller is compared by Unicode scalars.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

public typealias JSONObject = [String: JSONValue]

extension JSONValue {
    public init(_ integer: some BinaryInteger) { self = .number(Double(integer)) }

    public var objectValue: JSONObject? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// A number with no fraction (`10.0` counts) inside `range`, or `nil`. The one integer rule of
    /// every reader: tool arguments, the configuration, the allowance and the action log.
    func integer(in range: ClosedRange<Int>) -> Int? {
        guard case .number(let number) = self, number.rounded(.towardZero) == number,
            Double(range.lowerBound) <= number, number <= Double(range.upperBound)
        else { return nil }
        return Int(number)
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(uniqueKeysWithValues: elements))
    }
}

/// Anything deskhand sends as `structuredContent`.
public protocol JSONRepresentable {
    var jsonValue: JSONValue { get }
}

/// An RFC 6901 JSON Pointer into a tool call's `arguments`, or into a whole document.
public struct JSONPointer: Hashable, Sendable, CustomStringConvertible {
    public let tokens: [String]

    public init(_ tokens: [String] = []) { self.tokens = tokens }

    public static let root = JSONPointer()

    public func appending(_ token: String) -> JSONPointer { JSONPointer(tokens + [token]) }
    public func appending(_ index: Int) -> JSONPointer { appending(String(index)) }

    /// The rest of this pointer below `prefix`, or `nil` when it does not lie under `prefix`. Tokens
    /// are compared by Unicode scalars. A strict-JSON fault at `/params/arguments/a` is the argument
    /// fault `/a` (contract 2.4).
    public func relative(to prefix: JSONPointer) -> JSONPointer? {
        guard tokens.count >= prefix.tokens.count,
            zip(tokens, prefix.tokens).allSatisfy({ $0.hasSameScalars(as: $1) })
        else { return nil }
        return JSONPointer(Array(tokens.dropFirst(prefix.tokens.count)))
    }

    public var description: String {
        var text = ""
        for token in tokens {
            text.unicodeScalars.append("/")
            for scalar in token.unicodeScalars {
                switch scalar {
                case "~": text.unicodeScalars.append(contentsOf: "~0".unicodeScalars)
                case "/": text.unicodeScalars.append(contentsOf: "~1".unicodeScalars)
                default: text.unicodeScalars.append(scalar)
                }
            }
        }
        return text
    }
}
