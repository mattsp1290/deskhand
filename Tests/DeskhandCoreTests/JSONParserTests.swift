import DeskhandCore
import Testing

@Suite struct JSONParserTests {
    @Test func parsesEveryValueKind() throws {
        let parsed = try JSONValue(parsing: #" {"a": [1, 2.5, -3e2, true, false, null, "x"], "b": {}} "#)
        #expect(parsed == ["a": [1, 2.5, -300, true, false, nil, "x"], "b": [:]])
    }

    @Test func decodesEscapesAndSurrogatePairs() throws {
        let parsed = try JSONValue(parsing: #""\u00e9\ud83d\ude00\n\/\"\\\t""#)
        #expect(parsed == .string("é😀\n/\"\\\t"))
    }

    @Test func keepsNumbersAsDoubles() throws {
        #expect(try JSONValue(parsing: "10.0") == JSONValue(10))
        #expect(try JSONValue(parsing: "-0") == .number(-0.0))
        #expect(try JSONValue(parsing: "1E2") == .number(100))
    }

    @Test(arguments: [
        #"{"a": 1, "a": 2}"#, #"{"x": {"a": 1, "a": 1}}"#, "[1,]", #"{"a": 1,}"#, "01", "-", "1.", ".5", "+1",
        "1e", "NaN", "Infinity", "1e400", "-1e400", "tru", "nul", "{'a': 1}", #""\x""#, #""\u12""#,
        #""\ud800""#, #""\udc00""#, #""\ud800\u0041""#, "\"a\u{1}b\"", "\"abc", "[1] x", "", "[", "{\"a\" 1}",
    ])
    func rejectsInputThatIsNotIJSON(text: String) {
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: text) }
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: [0x22, 0xFF, 0x22]) }
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: [0x22, 0xC3, 0x22]) }
    }

    @Test func reportsTheOffsetOfADuplicateKey() throws {
        let error = try #require(throws: JSONParseError.self) { try JSONValue(parsing: #"{"a": 1, "a": 2}"#) }
        #expect(error.offset == 9)
    }

    @Test func limitsNesting() throws {
        let deepest = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
        _ = try JSONValue(parsing: deepest)
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: "[" + deepest + "]") }
    }
}
