import DeskhandCore

/// Why a client certificate that chains to the private CA is still refused at the handshake.
public enum ClientCertificateRefusal: Error, Hashable, Sendable, CustomStringConvertible {
    /// The leaf could not be read as X.509.
    case malformed(X509ParseError)
    /// The leaf has no extended key usage extension, or the extension does not list `clientAuth`.
    case missingClientAuthUsage
    /// The leaf's subject is not the one configured for this Mac. A subject is not a credential, so
    /// it is kept for the log.
    case unexpectedSubject(String)

    public var description: String {
        switch self {
        case .malformed(let error): "client certificate is malformed: \(error)"
        case .missingClientAuthUsage: "client certificate lacks extended key usage clientAuth"
        case .unexpectedSubject(let subject): "client certificate subject \(subject) is not the configured one"
        }
    }
}

/// Contract 2.2 as amended by D11: after BoringSSL has verified the chain to the private CA, the
/// leaf must carry EKU `clientAuth` and its subject must be the one configured for this Mac. The
/// principal is the RFC 4514 string of that subject (see ``DistinguishedName``).
public struct ClientCertificatePolicy: Hashable, Sendable {
    /// Compared with the RFC 4514 rendering of the presented subject, e.g. `CN=crew-executor,O=forge`,
    /// as a sequence of Unicode scalars, the way ``Principal`` compares: a canonically equivalent
    /// spelling is another certificate's subject.
    public let expectedSubject: String

    public init(expectedSubject: String) {
        self.expectedSubject = expectedSubject
    }

    public func authenticate(leafDER: [UInt8]) throws(ClientCertificateRefusal) -> Principal {
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
