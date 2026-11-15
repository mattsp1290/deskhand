import Foundation
import NIOSSL

/// A throwaway private CA, server and client certificates, generated once per test process with the
/// `openssl` command line (present on macOS and in the swift:6.2-noble image). Nothing here is a real
/// credential; every key lives in a fresh temporary directory.
struct TestPKI: Sendable {
    enum Client: CaseIterable, Sendable {
        case valid
        case wrongCA
        case serverAuthOnly
        case noExtendedKeyUsage
        case wrongSubject
        case reissued
    }

    struct Identity: Sendable {
        let certificate: NIOSSLCertificate
        let key: NIOSSLPrivateKey
        let certificatePath: String
        let keyPath: String
    }

    static let serverName = "deskhand-test.forge.svc"
    static let expectedSubject = "CN=crew-executor,O=forge"

    let directory: URL
    let caCertificate: NIOSSLCertificate
    let caPath: String
    let serverCertificatePath: String
    let serverKeyPath: String
    let clients: [Client: Identity]

    struct GenerationFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static let shared = Result { () throws(GenerationFailure) -> TestPKI in
        do { return try TestPKI.generate() } catch { throw GenerationFailure(description: "\(error)") }
    }

    static func get() throws -> TestPKI { try shared.get() }

    func identity(_ client: Client) -> Identity { clients[client]! }

    func opensslSubject(of path: String) throws -> String {
        let output = try Self.openssl(
            ["x509", "-in", path, "-noout", "-subject", "-nameopt", "RFC2253"], in: directory)
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line.hasPrefix("subject=") ? line.dropFirst("subject=".count) : Substring(line)
        // LibreSSL writes `subject= CN=...`, OpenSSL `subject=CN=...`.
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func generate() throws -> TestPKI {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskhand-listener-pki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try requestConfig.write(to: directory.appendingPathComponent("req.cnf"), atomically: true, encoding: .utf8)
        try extensionConfig.write(to: directory.appendingPathComponent("ext.cnf"), atomically: true, encoding: .utf8)

        try makeCA("ca", subject: "/O=deskhand-test/CN=Test Private CA", in: directory)
        try makeCA("other-ca", subject: "/O=deskhand-test/CN=Unrelated CA", in: directory)
        try makeLeaf("server", subject: "/CN=\(serverName)", ca: "ca", section: "server", serial: 2, in: directory)
        let leaves: [(Client, String, String, String, Int)] = [
            (.valid, "client", "/O=forge/CN=crew-executor", "client", 3),
            (.wrongCA, "client-wrong-ca", "/O=forge/CN=crew-executor", "client", 4),
            (.serverAuthOnly, "client-server-eku", "/O=forge/CN=crew-executor", "server_eku_only", 5),
            (.noExtendedKeyUsage, "client-no-eku", "/O=forge/CN=crew-executor", "no_eku", 6),
            (.wrongSubject, "client-wrong-subject", "/O=forge/CN=someone-else", "client", 7),
            (.reissued, "client-reissued", "/O=forge/CN=crew-executor", "client", 8),
        ]
        var clients: [Client: Identity] = [:]
        for (client, name, subject, section, serial) in leaves {
            let ca = client == .wrongCA ? "other-ca" : "ca"
            try makeLeaf(name, subject: subject, ca: ca, section: section, serial: serial, in: directory)
            let certificatePath = directory.appendingPathComponent("\(name).pem").path
            let keyPath = directory.appendingPathComponent("\(name).key").path
            clients[client] = Identity(
                certificate: try NIOSSLCertificate.fromPEMFile(certificatePath)[0],
                key: try NIOSSLPrivateKey(file: keyPath, format: .pem),
                certificatePath: certificatePath,
                keyPath: keyPath
            )
        }
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(file).path)
        }
        let caPath = directory.appendingPathComponent("ca.pem").path
        return TestPKI(
            directory: directory,
            caCertificate: try NIOSSLCertificate.fromPEMFile(caPath)[0],
            caPath: caPath,
            serverCertificatePath: directory.appendingPathComponent("server.pem").path,
            serverKeyPath: directory.appendingPathComponent("server.key").path,
            clients: clients
        )
    }

    private static func makeCA(_ name: String, subject: String, in directory: URL) throws {
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "\(name).key"], in: directory)
        try openssl(
            [
                "req", "-x509", "-new", "-key", "\(name).key", "-sha256", "-days", "30", "-subj", subject,
                "-config", "req.cnf", "-extensions", "v3_ca", "-out", "\(name).pem",
            ], in: directory)
    }

    private static func makeLeaf(
        _ name: String, subject: String, ca: String, section: String, serial: Int, in directory: URL
    ) throws {
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "\(name).key"], in: directory)
        try openssl(
            ["req", "-new", "-key", "\(name).key", "-subj", subject, "-config", "req.cnf", "-out", "\(name).csr"],
            in: directory)
        try openssl(
            [
                "x509", "-req", "-in", "\(name).csr", "-CA", "\(ca).pem", "-CAkey", "\(ca).key", "-set_serial",
                String(serial), "-days", "30", "-sha256", "-extfile", "ext.cnf", "-extensions", section, "-out",
                "\(name).pem",
            ], in: directory)
    }

    @discardableResult
    private static func openssl(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["openssl"] + arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw OpenSSLFailure(arguments: arguments, status: process.terminationStatus, output: text)
        }
        return text
    }

    struct OpenSSLFailure: Error, CustomStringConvertible {
        let arguments: [String]
        let status: Int32
        let output: String
        var description: String { "openssl \(arguments.joined(separator: " ")) exited \(status): \(output)" }
    }

    /// No `prompt = no`: LibreSSL (macOS /usr/bin/openssl) then ignores `-subj` or rejects the empty
    /// `[dn]` section.
    private static let requestConfig = """
        [req]
        distinguished_name = dn
        [dn]
        [v3_ca]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash

        """

    private static let extensionConfig = """
        [server]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature
        extendedKeyUsage = serverAuth
        subjectAltName = DNS:\(serverName)
        [client]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature
        extendedKeyUsage = clientAuth
        [server_eku_only]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature
        extendedKeyUsage = serverAuth
        [no_eku]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature

        """
}
