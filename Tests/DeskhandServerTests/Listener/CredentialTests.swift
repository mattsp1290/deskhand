import DeskhandCore
import Foundation
import Testing

@testable import DeskhandServer

@Suite struct BearerTokenTests {
    private let current = BearerToken(secret: Array("current-token".utf8))!
    private let previous = BearerToken(secret: Array("previous-token".utf8))!

    @Test func currentTokenMatchesExactly() {
        let tokens = AcceptedTokens(current: current)
        #expect(tokens.accepts("current-token".utf8, at: .now))
        #expect(!tokens.accepts("current-toke".utf8, at: .now))
        #expect(!tokens.accepts("current-token ".utf8, at: .now))
        #expect(!tokens.accepts("".utf8, at: .now))
    }

    @Test func previousTokenIsAcceptedOnlyInsideTheOverlapWindow() {
        let start = ContinuousClock.now
        let tokens = AcceptedTokens(
            current: current,
            previous: .init(token: previous, acceptedUntil: start + .seconds(10))
        )
        #expect(tokens.accepts("previous-token".utf8, at: start))
        #expect(tokens.accepts("previous-token".utf8, at: start + .seconds(9)))
        #expect(!tokens.accepts("previous-token".utf8, at: start + .seconds(10)))
        #expect(tokens.accepts("current-token".utf8, at: start + .seconds(60)))
    }

    @Test func nothingIsAcceptedWithoutACurrentToken() {
        #expect(!AcceptedTokens.none.accepts("current-token".utf8, at: .now))
        #expect(!AcceptedTokens.none.accepts("".utf8, at: .now))
    }

    @Test func emptySecretIsNoTokenAndNoTokenPrintsItsSecret() {
        #expect(BearerToken(secret: [UInt8]()) == nil)
        #expect("\(current)" == "BearerToken(redacted)")
    }
}

@Suite struct CredentialFileTests {
    private static func scratchFile(mode: Int16, contents: String = "pem") throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deskhand-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("file").path
        #expect(FileManager.default.createFile(atPath: path, contents: Data(contents.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }

    @Test(arguments: [0o600, 0o400] as [Int16])
    func ownerOnlyFileIsRead(_ mode: Int16) throws {
        let path = try Self.scratchFile(mode: mode, contents: "hello")
        #expect(try CredentialFile.read(path: path) == Array("hello".utf8))
    }

    @Test(arguments: [0o644, 0o640, 0o604, 0o660, 0o601] as [Int16])
    func groupOrOtherAccessIsRefused(_ mode: Int16) throws {
        let path = try Self.scratchFile(mode: mode)
        #expect(throws: CredentialFileError.accessibleByOthers(mode: UInt32(mode))) {
            try CredentialFile.read(path: path)
        }
    }

    @Test func missingSymlinkAndDirectoryAreRefused() throws {
        let path = try Self.scratchFile(mode: 0o600)
        let link = path + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        #expect(throws: CredentialFileError.missing) { try CredentialFile.read(path: path + "-absent") }
        #expect(throws: CredentialFileError.notRegularFile) { try CredentialFile.read(path: link) }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        #expect(throws: CredentialFileError.notRegularFile) { try CredentialFile.read(path: directory) }
    }

    /// Reviewer repro: opening a FIFO with no writer blocked forever, before the regular-file check.
    @Test(.timeLimit(.minutes(1))) func fifoIsRefusedWithoutWaitingForAWriter() async throws {
        let path = try Self.scratchFile(mode: 0o600) + "-fifo"
        #expect(mkfifo(path, 0o600) == 0)
        let started = ContinuousClock.now
        #expect(throws: CredentialFileError.notRegularFile) { try CredentialFile.read(path: path) }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func deviceIsRefused() {
        #expect(throws: CredentialFileError.notRegularFile) { try CredentialFile.read(path: "/dev/null") }
    }

    /// The startup path: a server key readable by group and other stops the TLS context from loading.
    @Test func worldReadableKeyIsRefusedAtStartup() throws {
        let pki = try TestPKI.get()
        let key = try Self.scratchFile(
            mode: 0o600, contents: try String(contentsOfFile: pki.serverKeyPath, encoding: .utf8))
        #expect(throws: Never.self) {
            try ServerTLSCredentials.load(caPath: pki.caPath, certificatePath: pki.serverCertificatePath, keyPath: key)
        }
        try FileManager.default.setAttributes([.posixPermissions: Int16(0o644)], ofItemAtPath: key)
        let error = #expect(throws: ServerTLSError.self) {
            try ServerTLSCredentials.load(caPath: pki.caPath, certificatePath: pki.serverCertificatePath, keyPath: key)
        }
        guard case .file(let path, .accessibleByOthers(mode: 0o644)) = error else {
            Issue.record("expected a mode refusal, got \(String(describing: error))")
            return
        }
        #expect(path == key)
    }
}
