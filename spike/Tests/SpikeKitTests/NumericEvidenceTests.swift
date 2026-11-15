import Foundation
import Testing

@testable import SpikeKit

@Test func rawNumbersPreserveExactDecimalEvidence() throws {
  for text in [
    "-9223372036854775809", "-9223372036854775808.1", "9223372036854775807.1",
    "0.999999999999999999999", "1.000000000000000000001", "9007199254740992.1",
    "1e-324", "-1e-400", "1e999999999999999999999999", "1e-999999999999999999999999",
  ] {
    let value = try #require(JSON.parse(text))
    #expect(value.intValue == nil)
    #expect(value.compact() == text)
  }
  for (text, expected) in [
    ("-9223372036854775808", Int.min), ("9223372036854775807", Int.max),
    ("-92233720368547758080e-1", Int.min), ("92233720368547758070e-1", Int.max),
    ("1.0", 1), ("100e-2", 1), ("1e0", 1), ("1e+000000000000000000000000", 1),
    ("0e999999999999999999999999", 0), ("-0e-999999999999999999999999", 0),
  ] {
    #expect(JSON.parse(text)?.intValue == expected)
  }
  for text in ["1e-324", "-1e-400", "1e400"] {
    #expect(JSON.parse(text)?.doubleValue == nil)
  }
  #expect(JSON.parse("5e-324")?.doubleValue == Double.leastNonzeroMagnitude)
  #expect(JSON.parse("-5e-324")?.doubleValue == -Double.leastNonzeroMagnitude)
  #expect(JSON.parse("-0e-99999999999999999999")?.doubleValue == 0)
  for number in [1234567890.123, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude, 0.1]
  {
    #expect(JSON.parse(JSON.double(number).compact())?.doubleValue == number)
  }
  #expect(JSON.parse(JSON.double(-0.0).compact())?.doubleValue?.sign == .minus)
  #expect(JSON.double(.infinity).compact() == "null")
  #expect(JSON.double(.nan).compact() == "null")
}

@Test func foundationNumbersRetainTheirRepresentations() {
  for text in ["-9223372036854775809", "0.999999999999999999999", "1.000000000000000000001"] {
    let value = JSON.from(foundation: NSDecimalNumber(string: text))
    #expect(value.intValue == nil)
    #expect(value.compact() == text)
  }
  #expect(JSON.from(foundation: NSDecimalNumber.notANumber) == .null)
  #expect(JSON.from(foundation: NSNumber(value: UInt64.max)).compact() == String(UInt64.max))
  let floating = Double(Int.max).nextDown
  #expect(JSON.from(foundation: NSNumber(value: floating)) == .double(floating))
  #expect(JSON.from(foundation: NSNumber(value: floating)).intValue == Int(exactly: floating))
  #expect(JSON.from(foundation: NSNumber(value: true)) == .bool(true))
}

@Test func parserValidatesGrammarAndPreservesObjectSemantics() throws {
  for text in [
    "", " ", "01", "-01", "+1", ".1", "1.", "1e", "1e+", "--1", "NaN", "Infinity",
    "true false", "nullx", "[1,]", "{\"a\":1,}", "{a:1}", "[", "{", "[1 2]",
    "\"\\x\"", "\"\\uZZZZ\"", "\"\n\"", "\"unterminated", "/*x*/0",
  ] { #expect(JSON.parse(text) == nil, "\(text)") }
  for text in ["null", "true", "false", "\"ok\"", "[]", "{}", " \n1\t\r"] {
    #expect(JSON.parse(text) != nil)
  }
  #expect(JSON.parse("\"\\uD83D\\uDE00\"")?.stringValue == "😀")
  #expect(JSON.parse("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"")?.stringValue == "\"\\/\u{8}\u{c}\n\r\t")
  let duplicate = try #require(JSON.parse("{\"z\":0,\"a\":1,\"\\u0061\":2}"))
  #expect(duplicate.members?.map(\.key) == ["a", "z"])
  #expect(duplicate["a"]?.intValue == 2)
  #expect(
    JSON.obj([("z", .int(0)), ("a", .int(1)), ("z", .int(2))]).members?.map(\.key) == ["z", "a"])
  #expect(JSON.parse("1") == JSON.parse("1"))
  #expect(JSON.parse("1") != JSON.parse("1.0"))
  #expect(JSON.parse("1") != .int(1))
  #expect(
    JSON.parse(String(repeating: "[", count: 128) + "0" + String(repeating: "]", count: 128)) != nil
  )
  #expect(
    JSON.parse(String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129)) == nil
  )
}

@Test func parserBoundsInputBeforeAllocation() {
  let atLimit = "0" + String(repeating: " ", count: JSONParser.maximumBytes - 1)
  #expect(JSON.parse(atLimit)?.intValue == 0)
  #expect(JSON.parse(atLimit + " ") == nil)
  #expect(
    JSON.parse("\"" + String(repeating: "é", count: JSONParser.maximumBytes / 2) + "\"") == nil)
}
