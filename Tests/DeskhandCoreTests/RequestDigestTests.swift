import DeskhandCore
import Testing

/// A fixed test key: the bytes 0 to 31.
private let key = DigestKey(bytes: (0..<32).map { UInt8($0) })!

@Suite(.timeLimit(.minutes(1))) struct RequestDigestTests {
    private func digest(_ tool: ToolName, _ arguments: String, key: DigestKey = key) throws -> RequestDigest {
        try RequestDigest(tool: tool, arguments: #require(JSONValue(parsing: arguments).objectValue), key: key)
    }

    /// Golden values computed independently (HMAC-SHA-256 of the JCS text with Python's `hmac`; the
    /// same text's plain SHA-256 matches the values deskhand used before the key, which Node.js
    /// computed). A change here would orphan every persisted operation record, so it must be
    /// deliberate.
    @Test func matchesIndependentlyComputedDigests() throws {
        #expect(
            try digest(.displays, "{}").description
                == "3eb0ae3f893496629709f6df74524a38e2f1357b0eafe9a22ace206b83144aa1")
        let drag = try #require(Fixtures.json("examples/pointer.input.drag.json").objectValue)
        #expect(
            try RequestDigest(tool: .pointer, arguments: drag, key: key).description
                == "3616a1cbe0eb7a93d10f8f9d3dffbda48894b0559f14332a7156c54cecda7478")
    }

    /// Contract 12.1: a lost key makes every stored digest stop matching, which is the safe way.
    @Test func anotherKeyGivesAnotherDigest() throws {
        let other = DigestKey(bytes: [UInt8](repeating: 7, count: 32))!
        #expect(try digest(.displays, "{}") != digest(.displays, "{}", key: other))
        #expect(try digest(.displays, "{}", key: DigestKey.generate()) != digest(.displays, "{}"))
        #expect(DigestKey(bytes: [UInt8](repeating: 0, count: 31)) == nil)
        #expect(DigestKey(bytes: [UInt8](repeating: 0, count: 33)) == nil)
        #expect(DigestKey.generate().bytes.count == 32)
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
        let composed = try RequestDigest(tool: .keyboard, arguments: ["text": "\u{FB33}"], key: key)
        let decomposed = try RequestDigest(tool: .keyboard, arguments: ["text": "\u{05D3}\u{05BC}"], key: key)
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
