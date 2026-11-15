import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct JSONParserTests {
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

    @Test(arguments: ["1e-400", "-1e-400", "0.1e-399", "1e-324", "1e400"])
    func rejectsNumbersADoubleCannotHold(text: String) throws {
        let error = try #require(throws: JSONParseError.self) { try JSONValue(parsing: text) }
        #expect(error.kind == .numberOutOfRange)
        #expect(!error.kind.isStrictness)
    }

    @Test(arguments: ["5e-324", "4.9e-324", "1e-308", "-5e-324", "-4.9e-324", "-1e-308"])
    func subnormalNumbersRoundTripAndDecodeScreenshot(text: String) throws {
        let value = try JSONValue(parsing: text)
        #expect(value == .number(Double(text)!))
        #expect(try JSONValue(parsing: value.canonicalBytes()) == value)
        let arguments = try #require(
            JSONValue(
                parsing:
                    "{\"holder_id\":\"h\",\"region\":{\"x\":\(text),\"y\":0,\"width\":1,\"height\":1}}"
            ).objectValue)
        let screenshot = try ScreenshotArguments(arguments: arguments)
        #expect(screenshot.region?.x == Double(text))
    }

    @Test func zeroWithAnyExponentIsZero() throws {
        #expect(try JSONValue(parsing: "0e-400") == .number(0))
        #expect(try JSONValue(parsing: "-0.000e999") == .number(-0.0))
        #expect(try JSONValue(parsing: "2.2250738585072014e-308") == .number(.leastNormalMagnitude))
    }

    @Test func locatesEveryFault() throws {
        let cases: [(String, JSONParseError.Kind, JSONPointer)] = [
            (#"{"x": {"a": 1, "a": 1}}"#, .duplicateMemberName, JSONPointer(["x", "a"])),
            (#"{"x": [0, "\ud800"]}"#, .invalidUnicode, JSONPointer(["x", "1"])),
            (#"{"x": {"\udc00": 1}}"#, .invalidUnicode, JSONPointer(["x"])),
            ("{\"\u{E9}\": 1, \"e\u{301}\": 2}", .equivalentMemberNames, JSONPointer(["e\u{301}"])),
            (#"{"x": [1,]}"#, .syntax, JSONPointer(["x", "1"])),
        ]
        for (text, kind, location) in cases {
            let error = try #require(throws: JSONParseError.self) { try JSONValue(parsing: text) }
            #expect(error.kind == kind, "\(text)")
            #expect(error.location == location, "\(text)")
        }
        let surrogateBytes = try #require(throws: JSONParseError.self) {
            try JSONValue(parsing: [0x5B, 0x22, 0xED, 0xA0, 0x80, 0x22, 0x5D])
        }
        #expect(surrogateBytes.kind == .invalidUnicode && surrogateBytes.location == JSONPointer(["0"]))
    }

    @Test func aRequestBodyReportsStrictFaultsWithTheirLocation() throws {
        let body =
            #"{"method": "tools/call", "params": {"name": "keyboard", "arguments": {"a": 1, "a": 2, "t": "\ud800"}}}"#
        let parsed = try JSONValue.parsingRequestBody(Array(body.utf8))
        #expect(parsed.value["method"] == "tools/call")
        #expect(parsed.value["params"]?["arguments"]?["a"] == 1)
        let arguments = JSONPointer(["params", "arguments"])
        #expect(parsed.faults.map(\.kind) == [.duplicateMemberName, .invalidUnicode])
        #expect(parsed.faults.compactMap { $0.location.relative(to: arguments)?.description } == ["/a", "/t"])
        #expect(parsed.faults.allSatisfy { $0.kind.isStrictness })

        let clean = try JSONValue.parsingRequestBody(Array(#"{"id": 1}"#.utf8))
        #expect(clean.faults.isEmpty)
        #expect(throws: JSONParseError.self) { try JSONValue.parsingRequestBody(Array(#"{"a": 1, "a": 2"#.utf8)) }
        #expect(JSONPointer(["params"]).relative(to: arguments) == nil)
    }

    @Test func limitsNesting() throws {
        let deepest = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
        _ = try JSONValue(parsing: deepest)
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: "[" + deepest + "]") }
    }
}
