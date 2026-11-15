import DeskhandCore
import NIOSSL

/// Why a client certificate that chains to the private CA is still refused at the handshake.
public enum ClientCertificateRefusal: Error, Hashable, Sendable, CustomStringConvertible {
    /// The leaf could not be read as X.509.
    case malformed(X509ParseError)
    /// The leaf's validity period has not started.
    case notYetValid
    /// The leaf's validity period has ended.
    case expired
    /// The leaf has no extended key usage extension, or the extension does not list `clientAuth`.
    case missingClientAuthUsage
    /// The leaf's subject is not the one configured for this Mac. A subject is not a credential, so
    /// it is kept for the log.
    case unexpectedSubject(String)

    public var description: String {
        switch self {
        case .malformed(let error): "client certificate is malformed: \(error)"
        case .notYetValid: "client certificate is not valid yet"
        case .expired: "client certificate has expired"
        case .missingClientAuthUsage: "client certificate lacks extended key usage clientAuth"
        case .unexpectedSubject(let subject): "client certificate subject \(subject) is not the configured one"
        }
    }
}

/// Contract 2.2 as amended by D11: after BoringSSL has verified the chain to the private CA, the
/// leaf must be in date, carry EKU `clientAuth` and have the subject configured for this Mac. The
/// principal is the RFC 4514 string of that subject (see ``DistinguishedName``).
public struct ClientCertificatePolicy: Hashable, Sendable {
    /// Compared with the RFC 4514 rendering of the presented subject, e.g. `CN=crew-executor,O=forge`,
    /// as a sequence of Unicode scalars, the way ``Principal`` compares: a canonically equivalent
    /// spelling is another certificate's subject.
    public let expectedSubject: String

    public init(expectedSubject: String) {
        self.expectedSubject = expectedSubject
    }

    /// Run on every handshake. BoringSSL checks the dates only while it verifies the chain, which a
    /// resumed TLS session skips, so they are checked here as well.
    public func authenticate(_ leaf: NIOSSLCertificate, now: Timestamp) throws(ClientCertificateRefusal) -> Principal {
        try Self.checkDates(notBefore: Int64(leaf.notValidBefore), notAfter: Int64(leaf.notValidAfter), now: now)
        let der: [UInt8]
        do {
            der = try leaf.toDERBytes()
        } catch {
            throw .malformed(X509ParseError("certificate cannot be encoded as DER"))
        }
        return try authenticate(leafDER: der)
    }

    static func checkDates(notBefore: Int64, notAfter: Int64, now: Timestamp) throws(ClientCertificateRefusal) {
        let nowSeconds = now.millisecondsSinceEpoch / 1000
        if nowSeconds < notBefore { throw .notYetValid }
        if nowSeconds > notAfter { throw .expired }
    }

    func authenticate(leafDER: [UInt8]) throws(ClientCertificateRefusal) -> Principal {
        let usages: [String]?
        let subject: String
        do throws(X509ParseError) {
            let certificate = try X509Certificate(der: leafDER)
            usages = try certificate.extendedKeyUsages()
            subject = try DistinguishedName.rfc4514(certificate.subject)
        } catch {
            throw .malformed(error)
        }
        guard let usages, usages.contains(OID.clientAuth) else { throw .missingClientAuthUsage }
        let principal = Principal(certificateSubject: subject)
        guard !subject.isEmpty, principal == Principal(certificateSubject: expectedSubject) else {
            throw .unexpectedSubject(subject)
        }
        return principal
    }
}
