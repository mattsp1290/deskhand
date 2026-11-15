import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct ActionLogRedactionTests {
    static let typedTexts = [
        "Hunter2-Zq9-correct-horse",
        "pässwörd ünïcødé 🔑 ключ",
        #"quote"back\slash/QX7"#,
        "  leading-and-trailing-spaces-W3  ",
        String(repeating: "Kq", count: 512),
    ]

    @Test(arguments: typedTexts) func typedTextNeverReachesTheLine(text: String) async throws {
        let intent = try LogSamples.intent(keyboard: LogSamples.typing(text))
        let lines = [
            ActionLogLine(.intent(intent)),
            try await LogSamples.outcomeLine(.completed(eventsPosted: 2 * text.unicodeScalars.count), intent: intent),
        ]
        for line in lines {
            for fragment in Self.fragments(of: text, length: 5) {
                #expect(!Self.contains(line.bytes, fragment), "fragment \(fragment) of the typed text was logged")
            }
        }
        #expect(intent.action == .keyboard(.type(textLength: text.unicodeScalars.count)))
        #expect(
            lines[0].entry.jsonValue["action"] == ["type": "type", "text_length": JSONValue(text.unicodeScalars.count)])
    }

    @Test(arguments: typedTexts) func typedTextIsNotStoredInTheEntry(text: String) throws {
        let intent = try LogSamples.intent(keyboard: LogSamples.typing(text))
        let strings = Self.strings(in: intent)
        #expect(!strings.isEmpty)
        for fragment in Self.fragments(of: text, length: 5) {
            #expect(!strings.contains { $0.contains(fragment) })
        }
    }

    static let presses: [(JSONValue, JSONValue)] = [
        (["type": "press", "key": "p"], .null),
        (["type": "press", "key": "p", "modifiers": ["shift"]], .null),
        (["type": "press", "key": "e", "modifiers": ["option"]], .null),
        (["type": "press", "key": "space"], .null),
        (["type": "press", "key": "7", "modifiers": ["option", "shift"]], .null),
        (["type": "press", "key": "q", "modifiers": ["command"]], "q"),
        (["type": "press", "key": "c", "modifiers": ["control", "shift"]], "c"),
        (["type": "press", "key": "return"], "return"),
        (["type": "press", "key": "tab", "modifiers": ["shift"]], "tab"),
        (["type": "press", "key": "f12"], "f12"),
    ]

    @Test(arguments: presses) func characterKeysPressedAsTypingAreNotNamed(action: JSONValue, logged: JSONValue)
        throws
    {
        let line = ActionLogLine(.intent(try LogSamples.intent(keyboard: action)))
        #expect(line.entry.jsonValue["action"]?["key"] == logged)
        #expect(try ActionLogLine(verifying: line.bytes) == line)
    }

    @Test func noImageBytesOrCredentialsAreLogged() throws {
        let image = Array("fake image".utf8)
        let line = ActionLogLine(.intent(try LogSamples.intent(pointer: ["type": "click", "x": 3, "y": 4])))
        #expect(!Self.contains(line.bytes, image))
        #expect(line.entry.jsonValue["frame_sha256"] == .string(SHA256Hex(hashing: image).description))
        let members = try #require(line.entry.jsonValue.objectValue).keys
        #expect(
            Set(members) == [
                "schema_version", "kind", "time", "node_address", "principal", "holder_id", "operation_id", "tool",
                "frame_id", "frame_sha256", "frontmost_app", "action",
            ])
    }

    private static func fragments(of text: String, length: Int) -> [String] {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > length else { return [text] }
        return (0...(scalars.count - length)).map { String(String.UnicodeScalarView(scalars[$0..<($0 + length)])) }
    }

    private static func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
        contains(haystack, Array(needle.utf8))
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains {
            haystack[$0..<($0 + needle.count)].elementsEqual(needle)
        }
    }

    private static func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        return Mirror(reflecting: value).children.flatMap { strings(in: $0.value) }
    }
}
