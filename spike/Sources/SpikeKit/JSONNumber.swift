import Foundation

public nonisolated struct JSONNumber: Sendable, Equatable {
  let lexeme: String
  private let negative: Bool
  private let coefficient: [UInt8]
  private let fractionalDigits: Int
  private let exponent: Int

  public init?(_ text: String) {
    guard text.utf8.count <= JSONParser.maximumBytes else { return nil }
    let bytes = Array(text.utf8)
    var index = 0
    func digit(_ position: Int) -> Bool {
      position < bytes.count && (48...57).contains(bytes[position])
    }
    negative = bytes.first == 45
    if negative { index += 1 }
    let start = index
    guard digit(index) else { return nil }
    if bytes[index] == 48 {
      index += 1
    } else {
      while digit(index) { index += 1 }
    }
    var digits = Array(bytes[start..<index])
    var fraction = 0
    if index < bytes.count, bytes[index] == 46 {
      index += 1
      let fractionalStart = index
      while digit(index) { index += 1 }
      fraction = index - fractionalStart
      guard fraction > 0 else { return nil }
      digits.append(contentsOf: bytes[fractionalStart..<index])
    }
    var power = 0
    if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
      index += 1
      var exponentNegative = false
      if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
        exponentNegative = bytes[index] == 45
        index += 1
      }
      guard digit(index) else { return nil }
      let maximumRelevantExponent = bytes.count + 32
      while digit(index) {
        power = min(maximumRelevantExponent, power * 10 + Int(bytes[index] - 48))
        index += 1
      }
      if exponentNegative { power = -power }
    }
    guard index == bytes.count else { return nil }
    lexeme = text
    coefficient = digits
    fractionalDigits = fraction
    exponent = power
  }

  public var exactInt: Int? {
    guard let first = coefficient.firstIndex(where: { $0 != 48 }) else { return 0 }
    let shift = exponent - fractionalDigits
    var end = coefficient.count
    if shift < 0 {
      let discarded = -shift
      guard discarded < end - first,
        coefficient.suffix(discarded).allSatisfy({ $0 == 48 })
      else { return nil }
      end -= discarded
    }
    let padding = max(0, shift)
    let bound = negative ? String(Int.min).dropFirst() : Substring(String(Int.max))
    let count = end - first + padding
    guard count <= bound.utf8.count else { return nil }
    let magnitude =
      String(decoding: coefficient[first..<end], as: UTF8.self)
      + String(repeating: "0", count: padding)
    guard count < bound.utf8.count || magnitude <= bound else { return nil }
    return Int((negative ? "-" : "") + magnitude)
  }

  public var finiteDouble: Double? {
    if coefficient.allSatisfy({ $0 == 48 }) { return negative ? -0.0 : 0.0 }
    guard let value = Double(lexeme), value.isFinite, value != 0 else { return nil }
    return value
  }
}
