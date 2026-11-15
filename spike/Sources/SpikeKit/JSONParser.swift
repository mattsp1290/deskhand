import Foundation

nonisolated struct JSONParser {
  static let maximumBytes = 64 * 1024 * 1024
  static let maximumDepth = 128
  private let bytes: [UInt8]
  private var index = 0

  init?(_ text: String) {
    guard text.utf8.count <= Self.maximumBytes else { return nil }
    bytes = Array(text.utf8)
  }

  mutating func parse() -> JSON? {
    guard let result = value(depth: 0) else { return nil }
    whitespace()
    return index == bytes.count ? result : nil
  }

  private mutating func whitespace() {
    while index < bytes.count {
      switch bytes[index] {
      case 9, 10, 13, 32: index += 1
      default: return
      }
    }
  }

  private mutating func take(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }

  private mutating func value(depth: Int) -> JSON? {
    whitespace()
    guard index < bytes.count else { return nil }
    switch bytes[index] {
    case 34: return string().map(JSON.string)
    case 123:
      guard depth < Self.maximumDepth else { return nil }
      index += 1
      whitespace()
      var members: [String: JSON] = [:]
      if take(125) { return .object([]) }
      while true {
        guard let key = string() else { return nil }
        whitespace()
        guard take(58), let item = value(depth: depth + 1) else { return nil }
        members[key] = item
        whitespace()
        if take(125) {
          return .object(members.keys.sorted().map { JSON.Member($0, members[$0]!) })
        }
        guard take(44) else { return nil }
        whitespace()
      }
    case 91:
      guard depth < Self.maximumDepth else { return nil }
      index += 1
      whitespace()
      var items: [JSON] = []
      if take(93) { return .array(items) }
      while true {
        guard let item = value(depth: depth + 1) else { return nil }
        items.append(item)
        whitespace()
        if take(93) { return .array(items) }
        guard take(44) else { return nil }
      }
    case 110: return literal("null", .null)
    case 116: return literal("true", .bool(true))
    case 102: return literal("false", .bool(false))
    case 45, 48...57:
      let start = index
      while index < bytes.count,
        [45, 43, 46, 69, 101].contains(bytes[index])
          || (48...57).contains(bytes[index])
      { index += 1 }
      return JSONNumber(String(decoding: bytes[start..<index], as: UTF8.self)).map(JSON.number)
    default: return nil
    }
  }

  private mutating func literal(_ text: String, _ result: JSON) -> JSON? {
    guard bytes[index...].starts(with: text.utf8) else { return nil }
    index += text.utf8.count
    return result
  }

  private mutating func string() -> String? {
    let start = index
    guard take(34) else { return nil }
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if byte == 34 {
        return
          (try? JSONSerialization.jsonObject(
            with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) as? String
      }
      if byte == 92 {
        guard index < bytes.count else { return nil }
        index += 1
      }
    }
    return nil
  }
}
