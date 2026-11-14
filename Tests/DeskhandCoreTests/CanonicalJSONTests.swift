import DeskhandCore
import Testing

@Suite struct CanonicalJSONTests {
    /// RFC 8785 Appendix B: IEEE 754 bit patterns and their canonical JSON numbers.
    @Test(
        arguments: [
            (0x0000_0000_0000_0000, "0"),
            (0x8000_0000_0000_0000, "0"),
            (0x0000_0000_0000_0001, "5e-324"),
            (0x8000_0000_0000_0001, "-5e-324"),
            (0x7FEF_FFFF_FFFF_FFFF, "1.7976931348623157e+308"),
            (0xFFEF_FFFF_FFFF_FFFF, "-1.7976931348623157e+308"),
            (0x4340_0000_0000_0000, "9007199254740992"),
            (0xC340_0000_0000_0000, "-9007199254740992"),
            (0x4430_0000_0000_0000, "295147905179352830000"),
            (0x44B5_2D02_C7E1_4AF5, "9.999999999999997e+22"),
            (0x44B5_2D02_C7E1_4AF6, "1e+23"),
            (0x44B5_2D02_C7E1_4AF7, "1.0000000000000001e+23"),
            (0x444B_1AE4_D6E2_EF4E, "999999999999999700000"),
            (0x444B_1AE4_D6E2_EF4F, "999999999999999900000"),
            (0x444B_1AE4_D6E2_EF50, "1e+21"),
            (0x3EB0_C6F7_A0B5_ED8C, "9.999999999999997e-7"),
            (0x3EB0_C6F7_A0B5_ED8D, "0.000001"),
            (0x41B3_DE43_5555_5553, "333333333.3333332"),
            (0x41B3_DE43_5555_5554, "333333333.33333325"),
            (0x41B3_DE43_5555_5555, "333333333.3333333"),
            (0x41B3_DE43_5555_5556, "333333333.3333334"),
            (0x41B3_DE43_5555_5557, "333333333.33333343"),
            (0xBECB_F647_612F_3696, "-0.0000033333333333333333"),
            (0x4314_3FF3_C1CB_0959, "1424953923781206.2"),
        ] as [(UInt64, String)])
    func rfc8785NumberVectors(bits: UInt64, expected: String) throws {
        #expect(try JSONValue.number(Double(bitPattern: bits)).canonicalString() == expected)
    }

    @Test(
        arguments: [
            (1e21, "1e+21"), (1e-7, "1e-7"), (0.000001, "0.000001"), (1.2345678901234568e20, "123456789012345680000"),
            (-0.0, "0"), (4.5, "4.5"), (9_007_199_254_740_992, "9007199254740992"), (1e16, "10000000000000000"),
            (1e20, "100000000000000000000"), (100, "100"), (0.1, "0.1"), (1.5e-7, "1.5e-7"), (2e-3, "0.002"),
            (1e30, "1e+30"), (-1.5, "-1.5"), (18_446_744_073_709_551_616, "18446744073709552000"),
            (864.358803986711, "864.358803986711"),
        ] as [(Double, String)])
    func ecmaScriptNumberLayout(value: Double, expected: String) throws {
        #expect(try JSONValue.number(value).canonicalString() == expected)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteNumbersAreRefused(value: Double) {
        #expect(throws: NonFiniteNumberError.self) { try JSONValue.array([.number(value)]).canonicalBytes() }
    }

    /// RFC 8785 section 3.2.3: names sort by UTF-16 code units, so U+1F600 (a surrogate pair
    /// starting 0xD83D) sorts before U+FB33 although its code point is larger.
    @Test func membersSortByUTF16CodeUnits() throws {
        let input = try JSONValue(
            parsing: #"""
                {"\u20ac": "Euro Sign", "\r": "Carriage Return", "\ufb33": "Hebrew Letter Dalet With Dagesh",
                 "1": "One", "\ud83d\ude00": "Emoji: Grinning Face", "\u0080": "Control",
                 "\u00f6": "Latin Small Letter O With Diaeresis"}
                """#)
        let expected =
            #"{"\r":"Carriage Return","1":"One","\#u{80}":"Control","\#u{F6}":"Latin Small Letter O With Diaeresis","#
            + #""\#u{20AC}":"Euro Sign","\#u{1F600}":"Emoji: Grinning Face","\#u{FB33}":"Hebrew Letter Dalet With Dagesh"}"#
        #expect(try input.canonicalBytes() == Array(expected.utf8))
    }

    /// The worked example of RFC 8785 section 3.2.2.
    @Test func rfc8785Example() throws {
        let input = try JSONValue(
            parsing: #"""
                {
                  "numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001],
                  "string": "\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/",
                  "literals": [null, true, false]
                }
                """#)
        let expected =
            #"{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"#
            + #""string":"\#u{20AC}$\u000f\nA'B\"\\\\\"/"}"#
        #expect(try input.canonicalBytes() == Array(expected.utf8))
    }

    @Test func escapesOnlyWhatJSONRequires() throws {
        let text = "\u{0}\u{8}\u{9}\u{A}\u{C}\u{D}\u{1F}\u{7F}\u{2028}/é"
        let expected = #""\u0000\b\t\n\f\r\u001f"# + "\u{7F}\u{2028}/é\""
        #expect(try JSONValue.string(text).canonicalBytes() == Array(expected.utf8))
    }

    @Test func canonicalOutputParsesBackToTheSameValue() throws {
        let value: JSONValue = ["b": [1, 2.5, "x"], "a": ["nested": nil, "flag": true], "c": -0.000001]
        #expect(try JSONValue(parsing: value.canonicalBytes()) == value)
    }
}
