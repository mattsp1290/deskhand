import DeskhandCore
import NIOCore
import NIOSSL

/// Why a server certificate and key were not put into use (contract 11.1). Names a path, a check
/// or a configured name, never credential content.
public enum CertificateRejection: Error, Hashable, Sendable, CustomStringConvertible {
    case unreadable(path: String, CredentialFileError)
    /// A file is not PEM, holds no certificate, or the key is encrypted.
    case unparseable(String)
    case malformed(X509ParseError)
    case keyMismatch
    case notYetValid
    case expired
    /// The leaf names an issuer that is neither the private CA nor an intermediate in its file.
    case notIssuedByCA
    /// A configured Service DNS name is not among the leaf's subject alternative names.
    case missingServiceName(String)
    /// BoringSSL refused the chain or the handshake failed for another reason.
    case handshakeFailed(String)
    case contextRejected(String)

    public var description: String {
        switch self {
        case .unreadable(let path, let error): "\(path): \(error)"
        case .unparseable(let reason): reason
        case .malformed(let error): "server certificate is malformed: \(error)"
        case .keyMismatch: "server key does not match the server certificate"
        case .notYetValid: "server certificate is not valid yet"
        case .expired: "server certificate has expired"
        case .notIssuedByCA: "server certificate is not issued by the private CA"
        case .missingServiceName(let name): "server certificate does not name \(name) as a subject alternative name"
        case .handshakeFailed(let reason): "server certificate failed a TLS handshake against the private CA: \(reason)"
        case .contextRejected(let reason): "TLS context rejected the server credentials: \(reason)"
        }
    }
}

/// The checks of contract 11.1 that a new certificate and key pass before they replace the old
/// pair: the key matches the certificate, the certificate chains to the private CA and is in
/// date, and its subject alternative names include every configured Service DNS name.
public enum ServerPairValidator {
    public struct Accepted: Sendable {
        public let credentials: ServerTLSCredentials
        /// The production context (``ServerTLSCredentials/makeContext()``) for the listener.
        public let context: NIOSSLContext
    }

    static func structuralRejection(
        _ credentials: ServerTLSCredentials,
        serviceNames: [String],
        now: Timestamp
    ) -> CertificateRejection? {
        let leaf = credentials.certificateChain[0]
        let facts: CertificateFacts
        var issuers: [ArraySlice<UInt8>] = []
        do throws(X509ParseError) {
            facts = try CertificateFacts(der: try derBytes(leaf))
            for issuer in credentials.certificateChain.dropFirst() + credentials.trustRoots {
                issuers.append(try CertificateFacts(der: try derBytes(issuer)).subject)
            }
        } catch {
            return .malformed(error)
        }
        let nowSeconds = now.millisecondsSinceEpoch / 1000
        if nowSeconds < Int64(leaf.notValidBefore) { return .notYetValid }
        if nowSeconds > Int64(leaf.notValidAfter) { return .expired }
        guard issuers.contains(facts.issuer) else { return .notIssuedByCA }
        let present = Set(facts.dnsNames.map(asciiLowercased))
        if let missing = serviceNames.first(where: { !present.contains(asciiLowercased($0)) }) {
            return .missingServiceName(missing)
        }
        return nil
    }

    /// Runs every check; on success returns the context new connections should use.
    public static func validate(
        _ credentials: ServerTLSCredentials,
        serviceNames: [String],
        now: Timestamp,
        group: any EventLoopGroup,
        handshakeTimeout: TimeAmount = .seconds(5)
    ) async -> Result<Accepted, CertificateRejection> {
        if let rejection = structuralRejection(credentials, serviceNames: serviceNames, now: now) {
            return .failure(rejection)
        }
        let probeContext: NIOSSLContext
        do {
            probeContext = try TLSProbe.serverContext(credentials)
        } catch NIOSSLError.failedToLoadPrivateKey {
            // The key itself parsed when the credentials were read, so BoringSSL refusing it now
            // means it is not the certificate's key.
            return .failure(.keyMismatch)
        } catch {
            return .failure(.contextRejected(String(describing: error)))
        }
        if let failure = await TLSProbe.handshake(
            server: probeContext,
            trustRoots: credentials.trustRoots,
            serverName: serviceNames.first ?? "deskhand.invalid",
            group: group,
            timeout: handshakeTimeout
        ) {
            return .failure(.handshakeFailed(failure.description))
        }
        do {
            return .success(Accepted(credentials: credentials, context: try credentials.makeContext()))
        } catch {
            return .failure(.contextRejected(String(describing: error)))
        }
    }

    private static func derBytes(_ certificate: NIOSSLCertificate) throws(X509ParseError) -> [UInt8] {
        do {
            return try certificate.toDERBytes()
        } catch {
            throw X509ParseError("certificate cannot be encoded as DER")
        }
    }

    private static func asciiLowercased(_ name: String) -> String {
        String(decoding: name.utf8.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
    }
}
