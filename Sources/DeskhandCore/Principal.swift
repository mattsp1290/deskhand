/// The authenticated caller: the client certificate subject, as the RFC 4514 string of its DER
/// encoding (contract 1, 2.2). The bearer token is a credential checked per request and is
/// deliberately not part of this identity.
///
/// Two principals are equal only when their subjects are the same sequence of Unicode scalars.
/// Swift's `String` equality is canonical equivalence, under which `CN=café` written with a
/// precomposed `é` equals the same name written with a combining accent; RFC 4514 leaves non-ASCII
/// text unescaped, so both spellings reach this type, and they are different certificates.
public struct Principal: Hashable, Sendable, CustomStringConvertible {
    public let certificateSubject: String

    public init(certificateSubject: String) {
        self.certificateSubject = certificateSubject
    }

    public var description: String { certificateSubject }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.certificateSubject.unicodeScalars.elementsEqual(rhs.certificateSubject.unicodeScalars)
    }

    public func hash(into hasher: inout Hasher) {
        for byte in certificateSubject.utf8 { hasher.combine(byte) }
        hasher.combine(certificateSubject.utf8.count)
    }
}

extension String {
    /// Equality of Unicode scalar sequences, with no canonical equivalence: how deskhand compares
    /// every name and enumerated value it reads from a caller.
    func hasSameScalars(as other: String) -> Bool { unicodeScalars.elementsEqual(other.unicodeScalars) }
}
