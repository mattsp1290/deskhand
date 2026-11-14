import DeskhandCore
import Testing

@Suite struct RequestDigestTests {
    private func digest(_ tool: ToolName, _ arguments: String) throws -> RequestDigest {
        try RequestDigest(tool: tool, arguments: #require(JSONValue(parsing: arguments).objectValue))
    }

    /// Golden values computed independently (SHA-256 of the JCS text in Node.js). A change here
    /// would orphan every persisted operation record, so it must be deliberate.
    @Test func matchesIndependentlyComputedDigests() throws {
        #expect(
            try digest(.displays, "{}").description
                == "f013c6de5ff25ec8b945bd929289c1399a55dfdf730884f68850b56f26195fc7")
        let drag = try #require(Fixtures.json("examples/pointer.input.drag.json").objectValue)
        #expect(
            try RequestDigest(tool: .pointer, arguments: drag).description
                == "a8d3418c558d99152f70f63d71824e6250906ed3c398351de2459f19b0edde73")
    }

    @Test func ignoresMemberOrderWhitespaceAndNumberSpelling() throws {
        let compact = try digest(
            .pointer, #"{"holder_id":"h","frame_id":"f","operation_id":"o","action":{"type":"move","x":10,"y":20}}"#)
        let spaced = try digest(
            .pointer,
            """
            {
              "action": { "y": 20.0, "x": 1e1, "type": "move" },
              "operation_id": "o", "frame_id": "f", "holder_id": "h"
            }
            """)
        #expect(compact == spaced)
    }

    @Test func bindsEveryValueAndTheToolName() throws {
        let base = #"{"holder_id":"h","frame_id":"f","operation_id":"o","action":{"type":"press","key":"a"}}"#
        let different = #"{"holder_id":"h","frame_id":"f","operation_id":"o","action":{"type":"press","key":"b"}}"#
        #expect(try digest(.keyboard, base) != digest(.keyboard, different))
        #expect(try digest(.keyboard, base) != digest(.pointer, base))
    }

    /// Defaults are not filled in before hashing, so an explicit default is a different request.
    @Test func explicitDefaultIsADifferentRequest() throws {
        let implicit = #"{"holder_id":"h","frame_id":"f","operation_id":"o","action":{"type":"press","key":"a"}}"#
        let explicit =
            #"{"holder_id":"h","frame_id":"f","operation_id":"o","action":{"type":"press","key":"a","hold_ms":0}}"#
        #expect(try digest(.keyboard, implicit) != digest(.keyboard, explicit))
    }

    /// Swift's `==` treats canonically equivalent strings as equal; the digest must not.
    @Test func distinguishesUnicodeNormalizationForms() throws {
        let composed = try RequestDigest(tool: .keyboard, arguments: ["text": "\u{FB33}"])
        let decomposed = try RequestDigest(tool: .keyboard, arguments: ["text": "\u{05D3}\u{05BC}"])
        #expect(composed != decomposed)
    }

    @Test func hexRoundTrips() throws {
        let digest = try digest(.displays, "{}")
        #expect(SHA256Hex(hex: digest.description) == digest.sha256)
        #expect(SHA256Hex(hex: digest.description.uppercased()) == nil)
        #expect(SHA256Hex(hex: digest.description + "\n") == nil)
        #expect(SHA256Hex(hex: String(digest.description.dropLast())) == nil)
    }

    @Test func hashesBytes() {
        #expect(
            SHA256Hex(hashing: Array("abc".utf8)).description
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
