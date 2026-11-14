import DeskhandCore
import NIOSSL
import Synchronization

/// Why the server's TLS material could not be loaded. Names a path and a reason, never content.
public enum ServerTLSError: Error, Sendable, CustomStringConvertible {
    case file(path: String, CredentialFileError)
    case noCertificate(path: String)
    case unparseable(path: String)
    case contextRejected(String)

    public var description: String {
        switch self {
        case .file(let path, let error): "\(path): \(error)"
        case .noCertificate(let path): "\(path): no PEM certificate"
        case .unparseable(let path): "\(path): not a PEM certificate or unencrypted PEM private key"
        case .contextRejected(let reason): "TLS context rejected the credentials: \(reason)"
        }
    }
}

/// The parsed server credentials: the private CA (the only trust root for client certificates),
/// the server chain (leaf first) and its key.
public struct ServerTLSCredentials: Sendable {
    public let trustRoots: [NIOSSLCertificate]
    public let certificateChain: [NIOSSLCertificate]
    public let privateKey: NIOSSLPrivateKey

    public init(caPEM: [UInt8], certificatePEM: [UInt8], keyPEM: [UInt8]) throws(ServerTLSError) {
        try self.init(
            caPEM: caPEM, certificatePEM: certificatePEM, keyPEM: keyPEM,
            sources: (ca: "CA certificate", certificate: "server certificate", key: "server key"))
    }

    private init(
        caPEM: [UInt8], certificatePEM: [UInt8], keyPEM: [UInt8],
        sources: (ca: String, certificate: String, key: String)
    ) throws(ServerTLSError) {
        trustRoots = try Self.certificates(caPEM, path: sources.ca)
        certificateChain = try Self.certificates(certificatePEM, path: sources.certificate)
        do {
            privateKey = try NIOSSLPrivateKey(bytes: keyPEM, format: .pem)
        } catch {
            throw .unparseable(path: sources.key)
        }
    }

    /// Reads the three files through ``CredentialFile``, so a key, certificate or CA readable by
    /// group or other is refused here, at startup.
    public static func load(_ paths: CredentialsConfig) throws(ServerTLSError) -> ServerTLSCredentials {
        try load(
            caPath: paths.caCertificatePath,
            certificatePath: paths.serverCertificatePath,
            keyPath: paths.serverKeyPath
        )
    }

    public static func load(
        caPath: String,
        certificatePath: String,
        keyPath: String
    ) throws(ServerTLSError) -> ServerTLSCredentials {
        try ServerTLSCredentials(
            caPEM: try read(caPath),
            certificatePEM: try read(certificatePath),
            keyPEM: try read(keyPath),
            sources: (ca: caPath, certificate: certificatePath, key: keyPath)
        )
    }

    private static func read(_ path: String) throws(ServerTLSError) -> [UInt8] {
        do {
            return try CredentialFile.read(path: path)
        } catch {
            throw .file(path: path, error)
        }
    }

    private static func certificates(_ pem: [UInt8], path: String) throws(ServerTLSError) -> [NIOSSLCertificate] {
        let parsed: [NIOSSLCertificate]
        do {
            parsed = try NIOSSLCertificate.fromPEMBytes(pem)
        } catch {
            throw .unparseable(path: path)
        }
        guard !parsed.isEmpty else { throw .noCertificate(path: path) }
        return parsed
    }

    /// TLS 1.3 only, HTTP/1.1 only, and a client certificate that chains to the private CA alone.
    ///
    /// Verification is `noHostnameVerification`, not `fullVerification`: on a server NIOSSL's
    /// `fullVerification` also requires the client certificate to name the client's IP address,
    /// which Crew's certificate does not and cannot. The chain, validity and trust-root checks are
    /// the same in both modes; the subject and EKU checks of D11 run after them.
    public func makeContext() throws(ServerTLSError) -> NIOSSLContext {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificateChain.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        configuration.certificateVerification = .noHostnameVerification
        configuration.trustRoots = .certificates(trustRoots)
        configuration.additionalTrustRoots = []
        configuration.applicationProtocols = ["http/1.1"]
        do {
            return try NIOSSLContext(configuration: configuration)
        } catch {
            throw .contextRejected(String(describing: error))
        }
    }
}

/// The TLS context new connections are made from. Credential reload (deskhand-zkt0) validates a new
/// pair and calls ``replace(with:)``; connections already open keep the context they started with.
public final class ServerTLSContextHolder: Sendable {
    private let context: Mutex<NIOSSLContext>

    public init(_ context: NIOSSLContext) {
        self.context = Mutex(context)
    }

    /// The validated context whose configuration each connection's context copies.
    public var current: NIOSSLContext { context.withLock { $0 } }

    public func replace(with newContext: NIOSSLContext) {
        context.withLock { $0 = newContext }
    }

    /// A new context with ``current``'s configuration, for one connection. BoringSSL keeps the
    /// session-ticket keys and the session cache per context, so a session from any other
    /// connection cannot be resumed on this one and its client certificate is verified in full.
    public func makeConnectionContext() throws -> NIOSSLContext {
        try NIOSSLContext(configuration: current.configuration)
    }
}
