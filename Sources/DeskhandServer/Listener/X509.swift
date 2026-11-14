/// Why a certificate could not be read. The reason names the structure, never certificate content.
public struct X509ParseError: Error, Hashable, Sendable, CustomStringConvertible {
    public let reason: String

    init(_ reason: String) { self.reason = reason }

    public var description: String { reason }
}

/// One DER element: its single-byte tag, its content octets and the whole encoding.
struct DERElement {
    let tag: UInt8
    let content: ArraySlice<UInt8>
    let encoded: ArraySlice<UInt8>
}

/// Reads definite-length DER elements with low-number tags, which is everything an X.509
/// certificate's TBS, Name and extension structures use.
struct DERReader {
    private var bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }

    var isAtEnd: Bool { bytes.isEmpty }

    var nextTag: UInt8? { bytes.first }

    mutating func read() throws(X509ParseError) -> DERElement {
        let original = bytes
        guard let tag = bytes.popFirst() else { throw X509ParseError("truncated element") }
        guard tag & 0x1F != 0x1F else { throw X509ParseError("high tag number") }
        guard let first = bytes.popFirst() else { throw X509ParseError("truncated length") }
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard (1...4).contains(count), bytes.count >= count else { throw X509ParseError("bad length") }
            for _ in 0..<count { length = length << 8 | Int(bytes.removeFirst()) }
            guard length >= 0x80, length >> (8 * (count - 1)) != 0 else { throw X509ParseError("non-minimal length") }
        }
        guard bytes.count >= length else { throw X509ParseError("truncated content") }
        let content = bytes.prefix(length)
        bytes = bytes.dropFirst(length)
        return DERElement(tag: tag, content: content, encoded: original[original.startIndex..<content.endIndex])
    }

    mutating func read(tag: UInt8) throws(X509ParseError) -> DERElement {
        let element = try read()
        guard element.tag == tag else { throw X509ParseError("unexpected tag") }
        return element
    }
}

enum DERTag {
    static let boolean: UInt8 = 0x01
    static let integer: UInt8 = 0x02
    static let octetString: UInt8 = 0x04
    static let objectIdentifier: UInt8 = 0x06
    static let utf8String: UInt8 = 0x0C
    static let numericString: UInt8 = 0x12
    static let printableString: UInt8 = 0x13
    static let ia5String: UInt8 = 0x16
    static let visibleString: UInt8 = 0x1A
    static let universalString: UInt8 = 0x1C
    static let bmpString: UInt8 = 0x1E
    static let sequence: UInt8 = 0x30
    static let set: UInt8 = 0x31
    static let explicitVersion: UInt8 = 0xA0
    static let issuerUniqueID: UInt8 = 0x81
    static let subjectUniqueID: UInt8 = 0x82
    static let explicitExtensions: UInt8 = 0xA3
}

/// Object identifiers in dotted-decimal form.
enum OID {
    static let extendedKeyUsage = "2.5.29.37"
    static let clientAuth = "1.3.6.1.5.5.7.3.2"

    static func dotted(_ element: DERElement) throws(X509ParseError) -> String {
        guard element.tag == DERTag.objectIdentifier, !element.content.isEmpty, element.content.last! & 0x80 == 0
        else { throw X509ParseError("bad object identifier") }
        var arcs: [UInt64] = []
        var value: UInt64 = 0
        var arcStart = true
        for byte in element.content {
            guard !(arcStart && byte == 0x80) else { throw X509ParseError("non-minimal object identifier") }
            guard value >> 57 == 0 else { throw X509ParseError("object identifier arc too large") }
            value = value << 7 | UInt64(byte & 0x7F)
            arcStart = byte & 0x80 == 0
            if arcStart {
                arcs.append(value)
                value = 0
            }
        }
        let first = arcs[0]
        let head: [UInt64] = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80]
        return (head + arcs.dropFirst()).map(String.init).joined(separator: ".")
    }
}

/// The parts of an X.509 certificate the listener inspects. Signatures, validity and the chain are
/// BoringSSL's job; this reads only an already verified leaf.
struct X509Certificate {
    struct Extension {
        let oid: String
        let critical: Bool
        let value: ArraySlice<UInt8>
    }

    /// The subject `Name` element, tag and length included.
    let subject: DERElement
    let extensions: [Extension]

    init(der: [UInt8]) throws(X509ParseError) {
        var outer = DERReader(der[...])
        let certificate = try outer.read(tag: DERTag.sequence)
        guard outer.isAtEnd else { throw X509ParseError("trailing bytes after certificate") }
        var certificateReader = DERReader(certificate.content)
        var tbs = DERReader(try certificateReader.read(tag: DERTag.sequence).content)
        if tbs.nextTag == DERTag.explicitVersion { _ = try tbs.read() }
        _ = try tbs.read(tag: DERTag.integer)
        _ = try tbs.read(tag: DERTag.sequence)  // signature algorithm
        _ = try tbs.read(tag: DERTag.sequence)  // issuer
        _ = try tbs.read(tag: DERTag.sequence)  // validity
        subject = try tbs.read(tag: DERTag.sequence)
        _ = try tbs.read(tag: DERTag.sequence)  // subject public key info
        var extensions: [Extension] = []
        while let tag = tbs.nextTag {
            let element = try tbs.read()
            switch tag {
            case DERTag.issuerUniqueID, DERTag.subjectUniqueID: continue
            case DERTag.explicitExtensions: extensions = try Self.parseExtensions(element.content)
            default: throw X509ParseError("unexpected TBS member")
            }
        }
        self.extensions = extensions
    }

    private static func parseExtensions(_ content: ArraySlice<UInt8>) throws(X509ParseError) -> [Extension] {
        var wrapper = DERReader(content)
        var reader = DERReader(try wrapper.read(tag: DERTag.sequence).content)
        guard wrapper.isAtEnd else { throw X509ParseError("trailing bytes after extensions") }
        var extensions: [Extension] = []
        while !reader.isAtEnd {
            var fields = DERReader(try reader.read(tag: DERTag.sequence).content)
            let oid = try OID.dotted(try fields.read())
            var critical = false
            if fields.nextTag == DERTag.boolean {
                let flag = try fields.read()
                guard flag.content.count == 1 else { throw X509ParseError("bad critical flag") }
                critical = flag.content.first != 0
            }
            let value = try fields.read(tag: DERTag.octetString).content
            guard fields.isAtEnd else { throw X509ParseError("trailing bytes in extension") }
            // RFC 5280 4.2: a certificate must not carry the same extension twice.
            guard !extensions.contains(where: { $0.oid == oid }) else { throw X509ParseError("duplicate extension") }
            extensions.append(Extension(oid: oid, critical: critical, value: value))
        }
        return extensions
    }

    /// The key purposes of the extended key usage extension, or nil when the extension is absent.
    func extendedKeyUsages() throws(X509ParseError) -> [String]? {
        guard let usage = extensions.first(where: { $0.oid == OID.extendedKeyUsage }) else { return nil }
        var wrapper = DERReader(usage.value)
        var reader = DERReader(try wrapper.read(tag: DERTag.sequence).content)
        guard wrapper.isAtEnd else { throw X509ParseError("trailing bytes after key usages") }
        var purposes: [String] = []
        while !reader.isAtEnd { purposes.append(try OID.dotted(try reader.read())) }
        return purposes
    }
}

/// RFC 4514 string form of an X.501 `Name`.
///
/// RDNs are written last to first, separated by `,` with no spaces; the attributes of a
/// multi-valued RDN are joined by `+` in encoded order. The types RFC 4514 section 3 names (CN, L,
/// ST, O, OU, C, STREET, DC, UID) are written by short name with their string value escaped as in
/// section 2.4. Any other type is written as its dotted OID, and any value that is not a decodable
/// directory string as `#` and the lowercase hex of its DER encoding, as section 2.4 requires.
/// This matches `openssl x509 -noout -subject -nameopt RFC2253` for ASCII subjects.
enum DistinguishedName {
    static let shortNames: [String: String] = [
        "2.5.4.3": "CN",
        "2.5.4.7": "L",
        "2.5.4.8": "ST",
        "2.5.4.10": "O",
        "2.5.4.11": "OU",
        "2.5.4.6": "C",
        "2.5.4.9": "STREET",
        "0.9.2342.19200300.100.1.25": "DC",
        "0.9.2342.19200300.100.1.1": "UID",
    ]

    static func rfc4514(_ name: DERElement) throws(X509ParseError) -> String {
        guard name.tag == DERTag.sequence else { throw X509ParseError("name is not a sequence") }
        var reader = DERReader(name.content)
        var rdns: [String] = []
        while !reader.isAtEnd {
            var attributes = DERReader(try reader.read(tag: DERTag.set).content)
            var parts: [String] = []
            while !attributes.isAtEnd {
                var pair = DERReader(try attributes.read(tag: DERTag.sequence).content)
                let oid = try OID.dotted(try pair.read())
                let value = try pair.read()
                guard pair.isAtEnd else { throw X509ParseError("trailing bytes in attribute") }
                parts.append(attribute(oid: oid, value: value))
            }
            guard !parts.isEmpty else { throw X509ParseError("empty relative distinguished name") }
            rdns.append(parts.joined(separator: "+"))
        }
        return rdns.reversed().joined(separator: ",")
    }

    private static func attribute(oid: String, value: DERElement) -> String {
        if let short = shortNames[oid], let text = directoryString(value) { return short + "=" + escape(text) }
        let hex = Array("0123456789abcdef".utf8)
        let encoded = value.encoded.flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 0xF)]] }
        return (shortNames[oid] ?? oid) + "=#" + String(decoding: encoded, as: UTF8.self)
    }

    private static func directoryString(_ value: DERElement) -> String? {
        let content = Array(value.content)
        switch value.tag {
        case DERTag.utf8String:
            return String(validating: content, as: UTF8.self)
        case DERTag.printableString, DERTag.ia5String, DERTag.visibleString, DERTag.numericString:
            return content.allSatisfy({ $0 < 0x80 }) ? String(decoding: content, as: UTF8.self) : nil
        case DERTag.bmpString:
            guard content.count % 2 == 0 else { return nil }
            let units = stride(from: 0, to: content.count, by: 2).map {
                UInt16(content[$0]) << 8 | UInt16(content[$0 + 1])
            }
            return String(validating: units, as: UTF16.self)
        case DERTag.universalString:
            guard content.count % 4 == 0 else { return nil }
            var scalars = String.UnicodeScalarView()
            for offset in stride(from: 0, to: content.count, by: 4) {
                let code = content[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                guard let scalar = Unicode.Scalar(code) else { return nil }
                scalars.append(scalar)
            }
            return String(scalars)
        default:
            return nil
        }
    }

    /// RFC 4514 section 2.4.
    static func escape(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var out = ""
        for (index, scalar) in scalars.enumerated() {
            switch scalar {
            case "\"", "+", ",", ";", "<", ">", "\\":
                out += "\\" + String(scalar)
            case "\0":
                out += "\\00"
            case " " where index == 0 || index == scalars.count - 1, "#" where index == 0:
                out += "\\" + String(scalar)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
