import DeskhandServer
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Synchronization

/// Server certificates and keys to rotate between, generated once per test process with the
/// `openssl` command line and signed by ``TestPKI``'s private CA, so ``TestClient`` and the
/// ``TestPKI`` client identities work against every valid pair. Nothing here is a real credential.
struct RotationPKI: Sendable {
    enum Pair: String, CaseIterable, Sendable {
        /// Valid; the pair a test starts from.
        case first
        /// Valid; a different key and serial.
        case second
        /// `second`'s certificate with `first`'s key.
        case mismatchedKey
        /// Signed by an unrelated CA.
        case wrongCA
        /// Names the private CA as issuer but is signed by another key with the same subject.
        case forgedIssuer
        /// In date for one day only.
        case shortLived
        /// Lacks the second configured Service DNS name.
        case missingName
    }

    struct Files: Sendable {
        let certificatePath: String
        let keyPath: String
    }

    static let serviceNames = [TestPKI.serverName, "deskhand-test.forge.svc.cluster.local"]

    let directory: URL
    let caPath: String
    let pairs: [Pair: Files]

    func files(_ pair: Pair) -> Files { pairs[pair]! }

    func serialNumber(_ pair: Pair) throws -> [UInt8] {
        try NIOSSLCertificate.fromPEMFile(files(pair).certificatePath)[0].serialNumber
    }

    private static let shared = Result { () throws(TestPKI.GenerationFailure) -> RotationPKI in
        do { return try RotationPKI.generate() } catch { throw TestPKI.GenerationFailure(description: "\(error)") }
    }

    static func get() throws -> RotationPKI { try shared.get() }

    private static func generate() throws -> RotationPKI {
        let base = try TestPKI.get()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskhand-rotation-pki-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["ca", "other-ca"] {
            for suffix in ["pem", "key"] {
                try FileManager.default.copyItem(
                    at: base.directory.appendingPathComponent("\(name).\(suffix)"),
                    to: directory.appendingPathComponent("\(name).\(suffix)"))
            }
        }
        try extensionConfig.write(to: directory.appendingPathComponent("ext.cnf"), atomically: true, encoding: .utf8)
        try requestConfig.write(to: directory.appendingPathComponent("req.cnf"), atomically: true, encoding: .utf8)
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "forged-ca.key"], in: directory)
        try openssl(
            [
                "req", "-x509", "-new", "-key", "forged-ca.key", "-sha256", "-days", "30", "-subj",
                "/O=deskhand-test/CN=Test Private CA", "-config", "req.cnf", "-extensions", "v3_ca", "-out",
                "forged-ca.pem",
            ], in: directory)

        let leaves: [(Pair, ca: String, section: String, days: Int, serial: Int)] = [
            (.first, "ca", "both_names", 30, 100),
            (.second, "ca", "both_names", 30, 101),
            (.wrongCA, "other-ca", "both_names", 30, 102),
            (.forgedIssuer, "forged-ca", "both_names", 30, 103),
            (.shortLived, "ca", "both_names", 1, 104),
            (.missingName, "ca", "one_name", 30, 105),
        ]
        for leaf in leaves {
            let name = leaf.0.rawValue
            try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "\(name).key"], in: directory)
            try openssl(
                [
                    "req", "-new", "-key", "\(name).key", "-subj", "/CN=\(TestPKI.serverName)", "-config", "req.cnf",
                    "-out", "\(name).csr",
                ], in: directory)
            try openssl(
                [
                    "x509", "-req", "-in", "\(name).csr", "-CA", "\(leaf.ca).pem", "-CAkey", "\(leaf.ca).key",
                    "-set_serial", String(leaf.serial), "-days", String(leaf.days), "-sha256", "-extfile", "ext.cnf",
                    "-extensions", leaf.section, "-out", "\(name).pem",
                ], in: directory)
        }
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(file).path)
        }
        func path(_ file: String) -> String { directory.appendingPathComponent(file).path }
        var pairs: [Pair: Files] = [:]
        for leaf in leaves {
            pairs[leaf.0] = Files(
                certificatePath: path("\(leaf.0.rawValue).pem"), keyPath: path("\(leaf.0.rawValue).key"))
        }
        pairs[.mismatchedKey] = Files(certificatePath: path("second.pem"), keyPath: path("first.key"))
        return RotationPKI(directory: directory, caPath: path("ca.pem"), pairs: pairs)
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
            throw TestPKI.OpenSSLFailure(arguments: arguments, status: process.terminationStatus, output: text)
        }
        return text
    }

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
        [both_names]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature
        extendedKeyUsage = serverAuth
        subjectAltName = DNS:\(serviceNames[0]),DNS:\(serviceNames[1])
        [one_name]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature
        extendedKeyUsage = serverAuth
        subjectAltName = DNS:\(serviceNames[0])

        """
}

/// One test's credential directory: the four files a ``CredentialReloader`` watches, all 0600,
/// rewritten the way a rotation does it (a new file renamed into place).
struct CredentialDirectory {
    static let firstToken = "first-test-token"
    static let secondToken = "second-test-token"

    let directory: URL
    let pki: RotationPKI

    var caPath: String { directory.appendingPathComponent("ca.pem").path }
    var certificatePath: String { directory.appendingPathComponent("server.pem").path }
    var keyPath: String { directory.appendingPathComponent("server.key").path }
    var tokenPath: String { directory.appendingPathComponent("token").path }

    init(pair: RotationPKI.Pair = .first, token: String = firstToken) throws {
        pki = try RotationPKI.get()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskhand-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try replace(caPath, with: try Data(contentsOf: URL(fileURLWithPath: pki.caPath)))
        try install(pair)
        try writeToken(token)
    }

    func configuration(tokenOverlap: Duration = .zero) -> CredentialReloadConfiguration {
        CredentialReloadConfiguration(
            caCertificatePath: caPath,
            serverCertificatePath: certificatePath,
            serverKeyPath: keyPath,
            tokenPath: tokenPath,
            serviceNames: RotationPKI.serviceNames,
            tokenOverlap: tokenOverlap
        )
    }

    func install(_ pair: RotationPKI.Pair) throws {
        let files = pki.files(pair)
        try replace(certificatePath, with: try Data(contentsOf: URL(fileURLWithPath: files.certificatePath)))
        try replace(keyPath, with: try Data(contentsOf: URL(fileURLWithPath: files.keyPath)))
    }

    func writeToken(_ token: String) throws {
        try replace(tokenPath, with: Data((token + "\n").utf8))
    }

    func setTokenMode(_ mode: Int16) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tokenPath)
    }

    func removeToken() throws {
        try FileManager.default.removeItem(atPath: tokenPath)
    }

    private func replace(_ path: String, with contents: Data) throws {
        let staging = path + ".new-\(UUID().uuidString)"
        guard
            FileManager.default.createFile(atPath: staging, contents: contents, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        guard rename(staging, path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

final class CredentialEventLog: Sendable {
    private let events = Mutex<[CredentialEvent]>([])

    func record(_ event: CredentialEvent) { events.withLock { $0.append(event) } }

    var all: [CredentialEvent] { events.withLock { $0 } }
}

/// A clock a test moves by hand.
final class ManualClock<Value: Sendable>: Sendable {
    private let value: Mutex<Value>

    init(_ value: Value) { self.value = Mutex(value) }

    var now: Value { value.withLock { $0 } }

    func set(_ newValue: Value) { value.withLock { $0 = newValue } }
}

/// Connects as the valid ``TestPKI`` client and returns the serial number of the certificate the
/// server presents, without speaking HTTP.
enum PresentedCertificate {
    static func serialNumber(at address: SocketAddress, pki: TestPKI) async throws -> [UInt8] {
        let identity = pki.identity(.valid)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([pki.caCertificate])
        tls.minimumTLSVersion = .tlsv13
        tls.certificateChain = [.certificate(identity.certificate)]
        tls.privateKey = .privateKey(identity.key)
        let context = try NIOSSLContext(configuration: tls)
        let presented = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: [UInt8].self)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        try NIOSSLClientHandler(context: context, serverHostname: TestPKI.serverName) {
                            chain, verification in
                            presented.succeed(chain.first?.serialNumber ?? [])
                            verification.succeed(.certificateVerified)
                        })
                }
            }
            .connect(to: address).get()
        defer { channel.close(promise: nil) }
        let timer = channel.eventLoop.scheduleTask(in: .seconds(10)) {
            presented.fail(ChannelError.connectTimeout(.seconds(10)))
        }
        defer { timer.cancel() }
        return try await presented.futureResult.get()
    }
}

/// Waits until `condition` holds, polling every 20 ms, for at most `timeout`.
func eventually(timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try await condition()
}
