import DeskhandCore
import Testing

@Suite struct ListenAddressTests {
    /// Accepted literals and how they are written back.
    static let accepted: [(String, String, ListenAddress.Family)] = [
        ("10.0.0.149", "10.0.0.149", .ipv4),
        ("10.0.0.96", "10.0.0.96", .ipv4),
        ("192.168.1.20", "192.168.1.20", .ipv4),
        ("172.16.0.1", "172.16.0.1", .ipv4),
        ("8.8.8.8", "8.8.8.8", .ipv4),
        ("fd00::1", "fd00::1", .ipv6),
        ("2001:0DB8:0:0:0:0:0:1", "2001:db8::1", .ipv6),
        ("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1", .ipv6),
        ("fd00:0:0:1:0:0:0:1", "fd00:0:0:1::1", .ipv6),
        ("2001:db8:1:2:3:4:5:6", "2001:db8:1:2:3:4:5:6", .ipv6),
        ("2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1", .ipv6),
        ("::ffff:10.0.0.149", "::ffff:10.0.0.149", .ipv6),
        ("64:ff9b::10.0.0.1", "64:ff9b::a00:1", .ipv6),
        ("fd00::", "fd00::", .ipv6),
    ]

    @Test(arguments: accepted)
    func acceptsUnicastLiteral(_ text: String, _ canonical: String, _ family: ListenAddress.Family) throws {
        let address = try ListenAddress(text)
        #expect(address.description == canonical)
        #expect(address.family == family)
        #expect(address.bytes.count == (family == .ipv4 ? 4 : 16))
    }

    static let refused: [(String, ListenAddress.Refusal)] = [
        ("0.0.0.0", .unspecified),
        ("0.1.2.3", .unspecified),
        ("::", .unspecified),
        ("0:0:0:0:0:0:0:0", .unspecified),
        ("::ffff:0.0.0.0", .unspecified),
        ("127.0.0.1", .loopback),
        ("127.255.255.254", .loopback),
        ("::1", .loopback),
        ("::ffff:127.0.0.1", .loopback),
        ("169.254.10.20", .linkLocal),
        ("fe80::1", .linkLocal),
        ("febf::1", .linkLocal),
        ("224.0.0.1", .multicast),
        ("239.255.255.250", .multicast),
        ("ff02::1", .multicast),
        ("255.255.255.255", .reserved),
        ("240.0.0.1", .reserved),
    ]

    @Test(arguments: refused)
    func refusesNonUnicastLANAddress(_ text: String, _ refusal: ListenAddress.Refusal) {
        #expect(throws: ListenAddress.Problem.refused(refusal)) { try ListenAddress(text) }
    }

    static let notLiterals = [
        "", "localhost", "deskhand-m1max2021.forge.svc", "10.0.0", "10.0.0.149.1", "10.0.0.256", "010.0.0.1",
        "10.0.0.-1", "10.0.0.1 ", " 10.0.0.1", "10.0.0.1\n", "[::1]", "fe80::1%en0", "1::2::3", "1:::2",
        "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8::", "12345::1", "g::1", ":1", "1:", "::ffff:10.0.0",
        "1.2.3.4::", "10.0.0.149:8443", "0x0a.0.0.1",
    ]

    @Test(arguments: notLiterals)
    func refusesTextThatIsNotAnIPLiteral(_ text: String) {
        #expect(throws: ListenAddress.Problem.notIPLiteral) { try ListenAddress(text) }
    }

    @Test func linkLocalBoundaryIsFE80Slash10() throws {
        #expect(try ListenAddress("fec0::1").family == .ipv6)
        #expect(throws: ListenAddress.Problem.refused(.linkLocal)) { try ListenAddress("fe80::") }
    }
}
