import DeskhandCore
import Foundation
import NIOSSL
import Testing

@testable import DeskhandServer

/// Builds DER for hand-made `Name` values.
private enum DER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let count = content.count
        if count < 0x80 { return [tag, UInt8(count)] + content }
        var lengthBytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [tag, 0x80 | UInt8(lengthBytes.count)] + lengthBytes + content
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").map { UInt64($0)! }
        var content = base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) { content += base128(arc) }
        return tlv(DERTag.objectIdentifier, content)
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        var bytes = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return bytes
    }

    /// RDNs in encoded order; each attribute is (OID, value TLV).
    static func name(_ rdns: [[(String, [UInt8])]]) -> DERElement {
        let encoded = tlv(
            DERTag.sequence,
            rdns.flatMap { rdn in
                tlv(DERTag.set, rdn.flatMap { tlv(DERTag.sequence, oid($0.0) + $0.1) })
            }
        )
        var reader = DERReader(encoded[...])
        return try! reader.read()
    }

    static func utf8(_ text: String) -> [UInt8] { tlv(DERTag.utf8String, Array(text.utf8)) }

    /// A certificate with only what ``X509Certificate`` reads: `subject` and EKU `clientAuth`. The
    /// policy runs after BoringSSL has verified the chain, so nothing here is signed.
    static func clientLeaf(commonName: String) -> [UInt8] {
        let subject = tlv(
            DERTag.sequence, tlv(DERTag.set, tlv(DERTag.sequence, oid("2.5.4.3") + utf8(commonName))))
        let usage = tlv(DERTag.sequence, oid(OID.clientAuth))
        let extensions = tlv(
            DERTag.explicitExtensions,
            tlv(DERTag.sequence, tlv(DERTag.sequence, oid(OID.extendedKeyUsage) + tlv(DERTag.octetString, usage))))
        let empty = tlv(DERTag.sequence, [])
        let tbs = tlv(
            DERTag.sequence, tlv(DERTag.integer, [1]) + empty + empty + empty + subject + empty + extensions)
        return tlv(DERTag.sequence, tbs + empty + tlv(0x03, [0]))
    }
}

private let commonName = "2.5.4.3"
private let organization = "2.5.4.10"
private let organizationalUnit = "2.5.4.11"

@Suite struct DistinguishedNameTests {
    @Test func rdnsAreWrittenLastToFirst() throws {
        let name = DER.name([[(organization, DER.utf8("forge"))], [(commonName, DER.utf8("crew-executor"))]])
        #expect(try DistinguishedName.rfc4514(name) == "CN=crew-executor,O=forge")
    }

    @Test(arguments: [
        ("a,b", #"a\,b"#),
        (#""q""#, #"\"q\""#),
        (" lead", #"\ lead"#),
        ("trail ", #"trail\ "#),
        ("#hash", "\\#hash"),
        ("mid#dle", "mid#dle"),
        (#"a+b;c<d>e\f"#, #"a\+b\;c\<d\>e\\f"#),
        ("nul\u{0}", #"nul\00"#),
        ("café", "café"),
        ("", ""),
    ])
    func valuesAreEscapedPerRFC4514(_ value: String, _ expected: String) throws {
        let name = DER.name([[(commonName, DER.utf8(value))]])
        #expect(try DistinguishedName.rfc4514(name) == "CN=" + expected)
    }

    @Test func multiValuedRDNJoinsWithPlus() throws {
        let name = DER.name([[(commonName, DER.utf8("a")), (organizationalUnit, DER.utf8("b"))]])
        #expect(try DistinguishedName.rfc4514(name) == "CN=a+OU=b")
    }

    @Test func unknownTypeIsDottedWithHexValue() throws {
        let email = DER.tlv(DERTag.ia5String, Array("x@y".utf8))
        let name = DER.name([[("1.2.840.113549.1.9.1", email)]])
        #expect(try DistinguishedName.rfc4514(name) == "1.2.840.113549.1.9.1=#1603784079")
    }

    @Test func knownTypeWithNonStringValueIsHex() throws {
        let name = DER.name([[(commonName, DER.tlv(DERTag.integer, [1]))]])
        #expect(try DistinguishedName.rfc4514(name) == "CN=#020101")
    }

    @Test func invalidUTF8IsHex() throws {
        let name = DER.name([[(commonName, DER.tlv(DERTag.utf8String, [0xC3]))]])
        #expect(try DistinguishedName.rfc4514(name) == "CN=#0c01c3")
    }

    @Test func bmpAndPrintableStringsDecode() throws {
        let bmp = DER.tlv(DERTag.bmpString, [0x00, 0x68, 0x00, 0xE9])
        let printable = DER.tlv(DERTag.printableString, Array("US".utf8))
        let name = DER.name([[("2.5.4.6", printable)], [(commonName, bmp)]])
        #expect(try DistinguishedName.rfc4514(name) == "CN=hé,C=US")
    }

    @Test func emptyNameIsEmptyString() throws {
        #expect(try DistinguishedName.rfc4514(DER.name([])) == "")
    }

    @Test func truncatedNameThrows() {
        var reader = DERReader([DERTag.sequence, 0x05, DERTag.set, 0x03, 0x30][...])
        #expect(throws: X509ParseError.self) {
            let element = try reader.read()
            _ = try DistinguishedName.rfc4514(element)
        }
    }

    @Test(arguments: ["1.3.6.1.5.5.7.3.2", "2.5.29.37", "0.9.2342.19200300.100.1.25", "2.999.1"])
    func objectIdentifiersRoundTrip(_ dotted: String) throws {
        var reader = DERReader(DER.oid(dotted)[...])
        #expect(try OID.dotted(reader.read()) == dotted)
    }

    @Test func nonMinimalLengthIsRefused() {
        var reader = DERReader([DERTag.sequence, 0x81, 0x01, 0x00][...])
        #expect(throws: X509ParseError.self) { try reader.read() }
    }
}

@Suite struct ClientCertificatePolicyTests {
    private let policy = ClientCertificatePolicy(expectedSubject: TestPKI.expectedSubject)

    private func der(_ client: TestPKI.Client) throws -> [UInt8] {
        try TestPKI.get().identity(client).certificate.toDERBytes()
    }

    @Test func validLeafYieldsTheSubjectAsPrincipal() throws {
        #expect(try policy.authenticate(leafDER: der(.valid)) == Principal(certificateSubject: TestPKI.expectedSubject))
    }

    @Test(arguments: [TestPKI.Client.serverAuthOnly, .noExtendedKeyUsage])
    func leafWithoutClientAuthIsRefused(_ client: TestPKI.Client) throws {
        let leaf = try der(client)
        #expect(throws: ClientCertificateRefusal.missingClientAuthUsage) { try policy.authenticate(leafDER: leaf) }
    }

    @Test func otherSubjectIsRefused() throws {
        let leaf = try der(.wrongSubject)
        #expect(throws: ClientCertificateRefusal.unexpectedSubject("CN=someone-else,O=forge")) {
            try policy.authenticate(leafDER: leaf)
        }
    }

    /// D11: `é` precomposed and `e` with a combining acute are equal as `String`s but are different
    /// subjects, so neither spelling admits a certificate carrying the other.
    @Test func canonicallyEquivalentSubjectIsRefused() throws {
        let precomposed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(precomposed == decomposed)
        let leaf = DER.clientLeaf(commonName: precomposed)
        #expect(
            try ClientCertificatePolicy(expectedSubject: "CN=\(precomposed)").authenticate(leafDER: leaf)
                == Principal(certificateSubject: "CN=\(precomposed)"))
        #expect(throws: ClientCertificateRefusal.unexpectedSubject("CN=\(precomposed)")) {
            try ClientCertificatePolicy(expectedSubject: "CN=\(decomposed)").authenticate(leafDER: leaf)
        }
        let decomposedLeaf = DER.clientLeaf(commonName: decomposed)
        #expect(throws: ClientCertificateRefusal.unexpectedSubject("CN=\(decomposed)")) {
            try ClientCertificatePolicy(expectedSubject: "CN=\(precomposed)").authenticate(leafDER: decomposedLeaf)
        }
    }

    @Test func garbageIsMalformed() {
        let error = #expect(throws: ClientCertificateRefusal.self) {
            try policy.authenticate(leafDER: [0x30, 0x03, 0x02, 0x01])
        }
        guard case .malformed = error else {
            Issue.record("expected malformed, got \(String(describing: error))")
            return
        }
    }

    @Test(arguments: TestPKI.Client.allCases)
    func subjectRenderingMatchesOpenSSL(_ client: TestPKI.Client) throws {
        let pki = try TestPKI.get()
        let certificate = try X509Certificate(der: try pki.identity(client).certificate.toDERBytes())
        let ours = try DistinguishedName.rfc4514(certificate.subject)
        #expect(ours == (try pki.opensslSubject(of: pki.identity(client).certificatePath)))
    }
}
