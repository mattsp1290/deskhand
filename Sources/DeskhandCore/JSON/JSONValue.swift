/// An I-JSON (RFC 7493) value: what deskhand parses from a request and serializes into a response.
///
/// Numbers are IEEE 754 doubles because RFC 8785 canonicalization is defined over doubles. Swift
/// compares strings by canonical equivalence, so `==` on two values (and duplicate-key detection
/// in the parser) treats differently normalized strings as equal; serialization keeps the original
/// code points, so the canonical bytes and the request digest never conflate them.
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

/// An RFC 6901 JSON Pointer into a tool call's `arguments`.
public struct JSONPointer: Hashable, Sendable, CustomStringConvertible {
    public let tokens: [String]

    public init(_ tokens: [String] = []) { self.tokens = tokens }

    public static let root = JSONPointer()

    public func appending(_ token: String) -> JSONPointer { JSONPointer(tokens + [token]) }
    public func appending(_ index: Int) -> JSONPointer { appending(String(index)) }

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
