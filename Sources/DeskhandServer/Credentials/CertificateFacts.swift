struct CertificateFacts {
    static let subjectAlternativeNameOID = "2.5.29.17"
    /// `dNSName [2] IMPLICIT IA5String` in a `GeneralNames` sequence.
    static let dnsNameTag: UInt8 = 0x82

    let issuer: ArraySlice<UInt8>
    let subject: ArraySlice<UInt8>
    let dnsNames: [String]

    init(der: [UInt8]) throws(X509ParseError) {
        let certificate = try X509Certificate(der: der)
        var outer = DERReader(der[...])
        var certificateReader = DERReader(try outer.read(tag: DERTag.sequence).content)
        var tbs = DERReader(try certificateReader.read(tag: DERTag.sequence).content)
        if tbs.nextTag == DERTag.explicitVersion { _ = try tbs.read() }
        _ = try tbs.read(tag: DERTag.integer)
        _ = try tbs.read(tag: DERTag.sequence)
        issuer = try tbs.read(tag: DERTag.sequence).encoded
        subject = certificate.subject.encoded
        dnsNames = try Self.dnsNames(certificate)
    }

    private static func dnsNames(_ certificate: X509Certificate) throws(X509ParseError) -> [String] {
        guard let names = certificate.extensions.first(where: { $0.oid == subjectAlternativeNameOID }) else {
            return []
        }
        var wrapper = DERReader(names.value)
        var reader = DERReader(try wrapper.read(tag: DERTag.sequence).content)
        guard wrapper.isAtEnd else { throw X509ParseError("trailing bytes after subject alternative names") }
        var dnsNames: [String] = []
        while !reader.isAtEnd {
            let name = try reader.read()
            guard name.tag == dnsNameTag else { continue }
            guard name.content.allSatisfy({ $0 < 0x80 }) else { throw X509ParseError("non-ASCII DNS name") }
            dnsNames.append(String(decoding: name.content, as: UTF8.self))
        }
        return dnsNames
    }
}
