import DeskhandCore
import Testing

@Suite struct NodeAddressTests {
    static let canonical: [([UInt8], String)] = [
        ([10, 0, 0, 149], "10.0.0.149"),
        ([0, 0, 0, 0], "0.0.0.0"),
        ([255, 255, 255, 255], "255.255.255.255"),
        ([0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 10) + [0, 1], "2001:db8::1"),
        ([0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1], "2001:db8:0:1::1"),
        ([0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1], "2001:db8::1:0:0:1"),
        ([0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1], "2001:db8:0:1:1:1:1:1"),
        (Array(repeating: 0, count: 16), "::"),
        (Array(repeating: 0, count: 15) + [1], "::1"),
        ([0xFE, 0x80] + Array(repeating: 0, count: 14), "fe80::"),
        ([0x20, 0x01, 0x0D, 0xB8, 0xAB, 0xCD, 0, 0x12, 0, 0, 0, 0, 0, 0, 0, 0], "2001:db8:abcd:12::"),
    ]

    @Test(arguments: canonical) func writesAndParsesTheCanonicalForm(bytes: [UInt8], text: String) throws {
        let address = try #require(NodeAddress(bytes: bytes))
        #expect(address.description == text)
        #expect(NodeAddress(text) == address)
    }

    @Test func ipv4MappedAddressIsLoggedAsIPv4() throws {
        let mapped: [UInt8] = Array(repeating: 0, count: 10) + [0xFF, 0xFF, 10, 0, 0, 96]
        #expect(try #require(NodeAddress(bytes: mapped)).description == "10.0.0.96")
        #expect(NodeAddress("::ffff:a00:60") == nil)
    }

    @Test(arguments: [
        "", "10.0.0", "10.0.0.256", "10.0.0.01", "010.0.0.1", " 10.0.0.1", "10.0.0.1\n", "2001:DB8::1",
        "2001:0db8::1", "2001:db8:0:0:0:0:0:1", "2001:db8::0:1", "1::2::3", "1:2:3:4:5:6:7:8:9", "::ffff:10.0.0.1",
        "fe80::1%en0", "localhost", "+1::",
    ])
    func refusesAnythingElse(text: String) {
        #expect(NodeAddress(text) == nil)
    }

    @Test(arguments: [0, 3, 5, 15, 17]) func refusesOtherByteCounts(count: Int) {
        #expect(NodeAddress(bytes: Array(repeating: 1, count: count)) == nil)
    }
}
