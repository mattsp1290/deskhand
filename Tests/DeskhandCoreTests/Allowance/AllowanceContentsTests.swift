import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct AllowanceContentsTests {
    @Test func decodesTheContractExample() throws {
        let allowance = try Allowance(contents: Array(AllowanceSample.json().utf8))
        #expect(allowance.mac == AllowanceSample.mac)
        #expect(allowance.notBefore == AllowanceSample.notBefore)
        #expect(allowance.expiresAt == AllowanceSample.expiresAt)
    }

    struct Rejection: CustomTestStringConvertible, Sendable {
        let label: String
        let contents: String
        let reason: AllowanceInvalidReason
        var testDescription: String { label }
    }

    static let rejections: [Rejection] = [
        Rejection(label: "not JSON", contents: "allow", reason: .malformedJSON),
        Rejection(label: "empty", contents: "", reason: .malformedJSON),
        Rejection(label: "trailing data", contents: AllowanceSample.json() + "{}", reason: .malformedJSON),
        Rejection(
            label: "duplicate member", contents: AllowanceSample.json(extra: #", "mac": "x""#), reason: .malformedJSON),
        Rejection(label: "array", contents: "[]", reason: .notAnObject),
        Rejection(label: "string", contents: #""allow""#, reason: .notAnObject),
        Rejection(
            label: "unknown member", contents: AllowanceSample.json(extra: #", "ttl": 5"#),
            reason: .unknownMember("ttl")),
        Rejection(
            label: "no version", contents: #"{"mac": "m", "not_before": "x", "expires_at": "y"}"#,
            reason: .missingMember("version")),
        Rejection(
            label: "no mac", contents: #"{"version": 1, "not_before": "x", "expires_at": "y"}"#,
            reason: .missingMember("mac")),
        Rejection(
            label: "no not_before", contents: #"{"version": 1, "mac": "m", "expires_at": "y"}"#,
            reason: .missingMember("not_before")),
        Rejection(
            label: "no expires_at", contents: #"{"version": 1, "mac": "m", "not_before": "x"}"#,
            reason: .missingMember("expires_at")),
        Rejection(label: "version 2", contents: AllowanceSample.json(version: "2"), reason: .unsupportedVersion),
        Rejection(label: "version 0", contents: AllowanceSample.json(version: "0"), reason: .unsupportedVersion),
        Rejection(label: "version 1.5", contents: AllowanceSample.json(version: "1.5"), reason: .unsupportedVersion),
        Rejection(
            label: "version string", contents: AllowanceSample.json(version: #""1""#), reason: .unsupportedVersion),
        Rejection(label: "version true", contents: AllowanceSample.json(version: "true"), reason: .unsupportedVersion),
        Rejection(label: "version null", contents: AllowanceSample.json(version: "null"), reason: .unsupportedVersion),
        Rejection(label: "mac empty", contents: AllowanceSample.json(mac: #""""#), reason: .malformedMac),
        Rejection(label: "mac upper case", contents: AllowanceSample.json(mac: #""Lunus""#), reason: .malformedMac),
        Rejection(label: "mac with dot", contents: AllowanceSample.json(mac: #""lunus.local""#), reason: .malformedMac),
        Rejection(
            label: "mac 64 characters", contents: AllowanceSample.json(mac: "\"\(String(repeating: "a", count: 64))\""),
            reason: .malformedMac),
        Rejection(label: "mac number", contents: AllowanceSample.json(mac: "7"), reason: .malformedMac),
        Rejection(
            label: "expires_at equals not_before",
            contents: AllowanceSample.json(expiresAt: #""2026-11-14T15:00:00Z""#),
            reason: .expiresNotAfterNotBefore),
        Rejection(
            label: "expires_at before not_before",
            contents: AllowanceSample.json(expiresAt: #""2026-11-14T14:59:59.999Z""#),
            reason: .expiresNotAfterNotBefore),
        Rejection(
            label: "expires_at equal at nanosecond precision",
            contents: AllowanceSample.json(
                notBefore: #""2026-11-14T15:00:00.5Z""#, expiresAt: #""2026-11-14T15:00:00.500000000Z""#),
            reason: .expiresNotAfterNotBefore),
    ]

    @Test(arguments: rejections)
    func rejects(_ rejection: Rejection) {
        #expect(throws: rejection.reason) { try Allowance(contents: Array(rejection.contents.utf8)) }
    }

    static let malformedTimestamps = [
        "2026-11-14T15:00:00+00:00",
        "2026-11-14T15:00:00z",
        "2026-11-14T15:00:00",
        "2026-11-14t15:00:00Z",
        "2026-11-14 15:00:00Z",
        "2026-13-14T15:00:00Z",
        "2026-00-14T15:00:00Z",
        "2026-11-00T15:00:00Z",
        "2026-11-31T15:00:00Z",
        "2026-02-30T15:00:00Z",
        "2026-02-29T15:00:00Z",
        "2100-02-29T15:00:00Z",
        "2026-11-14T25:00:00Z",
        "2026-11-14T24:00:00Z",
        "2026-11-14T15:60:00Z",
        "2026-11-14T15:00:60Z",
        "2026-11-14T15:00:00.Z",
        "2026-11-14T15:00:00.1234567890Z",
        "2026-11-14T15:00:00,5Z",
        "2026-11-14T15:00:0aZ",
        "+026-11-14T15:00:00Z",
        "2026-1-14T15:00:00Z",
        "2026-11-14T15:00:00Z\n",
        "",
    ]

    @Test(arguments: malformedTimestamps)
    func rejectsATimestampThatIsNotARealUTCInstant(_ text: String) {
        let quoted = "\"\(text.replacingNewlines)\""
        #expect(throws: AllowanceInvalidReason.malformedTimestamp("not_before")) {
            try Allowance(
                contents: Array(AllowanceSample.json(notBefore: quoted, expiresAt: #""9999-12-31T23:59:59Z""#).utf8))
        }
        #expect(throws: AllowanceInvalidReason.malformedTimestamp("expires_at")) {
            try Allowance(
                contents: Array(AllowanceSample.json(notBefore: #""1970-01-01T00:00:00Z""#, expiresAt: quoted).utf8))
        }
    }

    @Test func rejectsATimestampThatIsNotAString() {
        #expect(throws: AllowanceInvalidReason.malformedTimestamp("expires_at")) {
            try Allowance(contents: Array(AllowanceSample.json(expiresAt: "1794668520000").utf8))
        }
    }

    @Test(arguments: [
        ("2028-02-29T00:00:00Z", 1_835_395_200_000),
        ("2000-02-29T12:00:00Z", 951_825_600_000),
        ("2026-11-14T15:00:00.5Z", 1_794_668_400_500),
        ("2026-11-14T15:00:00.123Z", 1_794_668_400_123),
        ("2026-11-14T15:00:00.123000000Z", 1_794_668_400_123),
        ("2026-11-14T15:00:00.000000001Z", 1_794_668_400_001),
        ("2026-11-14T15:00:00.123456789Z", 1_794_668_400_124),
        ("1970-01-01T00:00:00Z", 0),
    ])
    func readsATimestampRoundedUpToTheMillisecond(_ text: String, _ milliseconds: Int64) throws {
        let allowance = try Allowance(
            contents: Array(
                AllowanceSample.json(notBefore: "\"\(text)\"", expiresAt: #""9999-12-31T23:59:59.999999999Z""#).utf8))
        #expect(allowance.notBefore == Timestamp(millisecondsSinceEpoch: milliseconds))
        #expect(allowance.expiresAt == Timestamp(millisecondsSinceEpoch: 253_402_300_800_000))
    }
}

extension String {
    /// A JSON string escape for the one control character the table uses.
    fileprivate var replacingNewlines: String {
        var escaped = ""
        for character in self { escaped += character == "\n" ? "\\n" : String(character) }
        return escaped
    }
}
