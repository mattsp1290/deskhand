import Foundation

/// A JSON value with ordered object members, so evidence files diff cleanly between runs.
public nonisolated enum JSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSON])
  case object([Member])

  public struct Member: Sendable, Equatable {
    public let key: String
    public let value: JSON

    public init(_ key: String, _ value: JSON) {
      self.key = key
      self.value = value
    }
  }

  /// Builds an object from key/value pairs; later duplicates replace earlier ones in place.
  public static func obj(_ pairs: [(String, JSON)]) -> JSON {
    var members: [Member] = []
    for (key, value) in pairs {
      if let index = members.firstIndex(where: { $0.key == key }) {
        members[index] = Member(key, value)
      } else {
        members.append(Member(key, value))
      }
    }
    return .object(members)
  }

  public static func str(_ value: String?) -> JSON { value.map(JSON.string).orNull }
  public static func num(_ value: Double?) -> JSON { value.map(JSON.double).orNull }
  public static func int(_ value: Int?) -> JSON { value.map(JSON.int).orNull }
  public static func bool(_ value: Bool?) -> JSON { value.map(JSON.bool).orNull }
  public static func strings(_ values: [String]) -> JSON { .array(values.map(JSON.string)) }

  public subscript(key: String) -> JSON? {
    guard case .object(let members) = self else { return nil }
    return members.last(where: { $0.key == key })?.value
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    switch self {
    case .int(let value): return Double(value)
    case .double(let value): return value
    default: return nil
    }
  }

  public var intValue: Int? {
    switch self {
    case .int(let value): return value
    case .double(let value) where value.isFinite: return Int(value)
    default: return nil
    }
  }

  public var arrayValue: [JSON]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var members: [Member]? {
    if case .object(let value) = self { return value }
    return nil
  }

  /// Returns a copy with `key` set (replacing an existing member in place).
  public func setting(_ key: String, _ value: JSON) -> JSON {
    guard case .object(var members) = self else { return self }
    if let index = members.firstIndex(where: { $0.key == key }) {
      members[index] = Member(key, value)
    } else {
      members.append(Member(key, value))
    }
    return .object(members)
  }

  // MARK: Serialization

  public func compact() -> String {
    var out = ""
    write(into: &out, indent: nil, level: 0)
    return out
  }

  public func pretty() -> String {
    var out = ""
    write(into: &out, indent: "  ", level: 0)
    return out + "\n"
  }

  private func write(into out: inout String, indent: String?, level: Int) {
    switch self {
    case .null: out += "null"
    case .bool(let value): out += value ? "true" : "false"
    case .int(let value): out += String(value)
    case .double(let value): out += JSON.format(value)
    case .string(let value): JSON.quote(value, into: &out)
    case .array(let items):
      guard !items.isEmpty else {
        out += "[]"
        return
      }
      out += "["
      for (index, item) in items.enumerated() {
        if index > 0 { out += "," }
        JSON.newline(&out, indent, level + 1)
        item.write(into: &out, indent: indent, level: level + 1)
      }
      JSON.newline(&out, indent, level)
      out += "]"
    case .object(let members):
      guard !members.isEmpty else {
        out += "{}"
        return
      }
      out += "{"
      for (index, member) in members.enumerated() {
        if index > 0 { out += "," }
        JSON.newline(&out, indent, level + 1)
        JSON.quote(member.key, into: &out)
        out += indent == nil ? ":" : ": "
        member.value.write(into: &out, indent: indent, level: level + 1)
      }
      JSON.newline(&out, indent, level)
      out += "}"
    }
  }

  private static func newline(_ out: inout String, _ indent: String?, _ level: Int) {
    guard let indent else { return }
    out += "\n" + String(repeating: indent, count: level)
  }

  private static func format(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
    return String(format: "%.6g", value)
  }

  private static func quote(_ value: String, into out: inout String) {
    out += "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
  }

  // MARK: Parsing and bridging

  /// Parses one JSON document; `nil` when it is not valid JSON.
  public static func parse(_ text: String) -> JSON? {
    guard let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return nil }
    return from(foundation: object)
  }

  /// Converts a Foundation/CoreFoundation property-list-like value. Data becomes its length, dates
  /// become ISO 8601 strings, and anything else becomes its description.
  public static func from(foundation value: Any?) -> JSON {
    guard let value else { return .null }
    switch value {
    case is NSNull: return .null
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
      return .int(number.intValue)
    case let string as String: return .string(string)
    case let date as Date: return .string(Clock.iso(date))
    case let data as Data: return .obj([("data_bytes", .int(data.count))])
    case let array as [Any]: return .array(array.map { from(foundation: $0) })
    case let dict as [String: Any]:
      return .object(dict.keys.sorted().map { Member($0, from(foundation: dict[$0])) })
    case let dict as NSDictionary:
      var members: [Member] = []
      for key in dict.allKeys.map({ "\($0)" }).sorted() {
        members.append(Member(key, from(foundation: dict[key])))
      }
      return .object(members)
    default: return .string(String(describing: value))
    }
  }
}

extension Optional where Wrapped == JSON {
  /// The value, or JSON `null`; cheaper for the type checker than `?? .null` in long literals.
  public nonisolated var orNull: JSON {
    switch self {
    case .some(let value): value
    case .none: .null
    }
  }
}
