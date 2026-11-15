/// Arguments that break a tool's input schema or a contract rule. Answered as the tool error
/// `invalid_argument` with `details.argument` set to `pointer`, never as JSON-RPC `-32602`.
public struct ArgumentError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The offending value, or the object that lacks a required member or has an unknown one.
    public let pointer: JSONPointer
    public let message: String

    public init(at pointer: JSONPointer, _ message: String) {
        self.pointer = pointer
        self.message = message
    }

    public var description: String { "\(pointer.description.isEmpty ? "arguments" : pointer.description): \(message)" }
}

typealias ValueDecoder<T> = (JSONValue, JSONPointer) throws(ArgumentError) -> T

/// Member names are compared by Unicode scalars. A name that only canonically equals an allowed one
/// is unknown, so the `String`-keyed lookups that follow only ever see names spelled exactly.
struct ObjectReader {
    let members: JSONObject
    let path: JSONPointer

    init(_ value: JSONValue, at path: JSONPointer, allowing names: Set<String>) throws(ArgumentError) {
        guard case .object(let members) = value else { throw ArgumentError(at: path, "must be an object") }
        let unknownNames = members.keys.filter { key in !names.contains { $0.hasSameScalars(as: key) } }
        if let unknown = unknownNames.min() {
            throw ArgumentError(at: path, "unknown member '\(unknown)'")
        }
        self.members = members
        self.path = path
    }

    func optional<T>(_ name: String, _ decode: ValueDecoder<T>) throws(ArgumentError) -> T? {
        guard let value = members[name] else { return nil }
        return try decode(value, path.appending(name))
    }

    func required<T>(_ name: String, _ decode: ValueDecoder<T>) throws(ArgumentError) -> T {
        guard let value = members[name] else { throw ArgumentError(at: path, "missing required member '\(name)'") }
        return try decode(value, path.appending(name))
    }
}

enum Decode {
    static func integer(_ range: ClosedRange<Int>) -> ValueDecoder<Int> {
        { value, path throws(ArgumentError) in
            guard let integer = value.integer(in: range) else {
                throw ArgumentError(at: path, "must be an integer from \(range.lowerBound) to \(range.upperBound)")
            }
            return integer
        }
    }

    static func number(minimum: Double = -.infinity) -> ValueDecoder<Double> {
        { value, path throws(ArgumentError) in
            guard case .number(let number) = value, number >= minimum else {
                throw ArgumentError(
                    at: path, minimum.isFinite ? "must be a number of at least \(minimum)" : "must be a number")
            }
            return number
        }
    }

    static func string(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> String {
        guard case .string(let text) = value else { throw ArgumentError(at: path, "must be a string") }
        return text
    }

    static func identifier<ID: RestrictedIdentifier>(_ type: ID.Type) -> ValueDecoder<ID> {
        { value, path throws(ArgumentError) in
            guard let id = ID(try string(value, path)) else {
                throw ArgumentError(at: path, "must be \(ID.requirement)")
            }
            return id
        }
    }

    /// Matched by Unicode scalars, as the schema's `enum` is: U+037E GREEK QUESTION MARK is not `;`,
    /// although Swift's `String` equality says it is.
    static func oneOf<E: RawRepresentable & CaseIterable>(_ type: E.Type) -> ValueDecoder<E>
    where E.RawValue == String {
        { value, path throws(ArgumentError) in
            let text = try string(value, path)
            guard let member = E.allCases.first(where: { $0.rawValue.hasSameScalars(as: text) }) else {
                throw ArgumentError(at: path, "must be one of " + E.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return member
        }
    }

    static func uniqueArray<T: Hashable>(
        count: ClosedRange<Int>, _ element: @escaping ValueDecoder<T>
    ) -> ValueDecoder<[T]> {
        { value, path throws(ArgumentError) in
            guard case .array(let items) = value, count.contains(items.count) else {
                throw ArgumentError(at: path, "must be an array of \(count.lowerBound) to \(count.upperBound) items")
            }
            var seen = Set<T>()
            var decoded: [T] = []
            for (index, item) in items.enumerated() {
                let member = try element(item, path.appending(index))
                guard seen.insert(member).inserted else {
                    throw ArgumentError(at: path.appending(index), "is a duplicate")
                }
                decoded.append(member)
            }
            return decoded
        }
    }

    static func modifiers(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> Set<Modifier> {
        Set(try uniqueArray(count: 0...Modifier.allCases.count, oneOf(Modifier.self))(value, path))
    }

    static func permittedApps(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> Set<BundleID> {
        Set(try uniqueArray(count: ContractConstants.permittedAppsCountRange, identifier(BundleID.self))(value, path))
    }

    static func framePoint(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> FramePoint {
        let point = try ObjectReader(value, at: path, allowing: ["x", "y"])
        let coordinate = integer(FramePoint.coordinateRange)
        return FramePoint(x: try point.required("x", coordinate), y: try point.required("y", coordinate))
    }
}
