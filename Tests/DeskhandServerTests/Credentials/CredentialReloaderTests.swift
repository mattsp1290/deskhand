import DeskhandCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import DeskhandServer

private let day: Int64 = 86_400_000

@Suite struct ServerPairValidatorTests {
    private static func credentials(_ pair: RotationPKI.Pair) throws -> ServerTLSCredentials {
        let pki = try RotationPKI.get()
        let files = pki.files(pair)
        return try ServerTLSCredentials.load(
            caPath: pki.caPath, certificatePath: files.certificatePath, keyPath: files.keyPath)
    }

    private static func validate(
        _ pair: RotationPKI.Pair,
        now: Timestamp? = nil
    ) async throws -> CertificateRejection? {
        let credentials = try credentials(pair)
        let result = await ServerPairValidator.validate(
            credentials, serviceNames: RotationPKI.serviceNames, now: now ?? CredentialReloader.systemTime(),
            group: MultiThreadedEventLoopGroup.singleton)
        if case .failure(let rejection) = result { return rejection }
        return nil
    }

    @Test(arguments: [RotationPKI.Pair.first, .second])
    func validPairIsAccepted(_ pair: RotationPKI.Pair) async throws {
        #expect(try await Self.validate(pair) == nil)
    }

    @Test(arguments: [
        (RotationPKI.Pair.mismatchedKey, CertificateRejection.keyMismatch),
        (.wrongCA, .notIssuedByCA),
        (.missingName, .missingServiceName("deskhand-test.forge.svc.cluster.local")),
    ])
    func invalidPairIsRefusedWithItsReason(_ pair: RotationPKI.Pair, _ expected: CertificateRejection) async throws {
        #expect(try await Self.validate(pair) == expected)
    }

    @Test func certificateSignedByAnotherKeyUnderTheCAsNameFailsTheHandshake() async throws {
        let rejection = try await Self.validate(.forgedIssuer)
        guard case .handshakeFailed = rejection else {
            Issue.record("expected handshakeFailed, got \(String(describing: rejection))")
            return
        }
    }

    @Test func validityIsJudgedAtTheGivenTime() async throws {
        _ = try RotationPKI.get()
        let now = CredentialReloader.systemTime()
        #expect(try await Self.validate(.shortLived, now: now) == nil)
        #expect(try await Self.validate(.shortLived, now: now.adding(milliseconds: 2 * day)) == .expired)
        #expect(try await Self.validate(.shortLived, now: now.adding(milliseconds: -day)) == .notYetValid)
    }

    @Test func serviceNamesAreMatchedCaseInsensitivelyAndExactly() throws {
        let credentials = try Self.credentials(.first)
        let now = CredentialReloader.systemTime()
        let upper = RotationPKI.serviceNames.map { $0.uppercased() }
        #expect(ServerPairValidator.structuralRejection(credentials, serviceNames: upper, now: now) == nil)
        #expect(
            ServerPairValidator.structuralRejection(credentials, serviceNames: ["forge.svc"], now: now)
                == .missingServiceName("forge.svc"))
    }
}

@Suite struct TokenRotationTests {
    private static let old = "old-test-token-not-a-secret-0001"
    private static let new = "new-test-token-not-a-secret-0002"
    /// Exactly ``LoadedToken/minimumLength`` characters.
    private static let token = "token-0123456789abcdefghijklmnop"

    private static func loaded(_ secret: String) -> LoadedToken { LoadedToken.parse(Array(secret.utf8))! }

    private static let formats: [(String, Bool)] = {
        let short = String(token.dropLast())
        let valid: [String] = [token, token + "\n", token + "\r\n", "a.b-c_d~e+f/g=" + token]
        let invalid: [String] = [
            "", "\n", token + "\n\n", " " + token, "tok en" + token, token + "\t", "tökén" + token,
            token + "\u{7F}", short, short + "\n",
        ]
        return valid.map { ($0, true) } + invalid.map { ($0, false) }
    }()

    @Test(arguments: formats)
    func tokenFileFormat(_ contents: String, _ valid: Bool) {
        #expect(Self.token.utf8.count == LoadedToken.minimumLength)
        #expect((LoadedToken.parse(Array(contents.utf8)) != nil) == valid)
    }

    @Test func zeroOverlapRevokesTheReplacedTokenAtOnce() {
        let start = ContinuousClock.now
        var rotation = TokenRotation(overlap: .zero)
        let changed1 = rotation.apply(Self.loaded(Self.old), at: start)
        #expect(changed1)
        let changed2 = rotation.apply(Self.loaded(Self.new), at: start + .seconds(1))
        #expect(changed2)
        #expect(!rotation.accepted.accepts(Self.old.utf8, at: start + .seconds(1)))
        #expect(rotation.accepted.accepts(Self.new.utf8, at: start + .seconds(1)))
    }

    @Test func overlapKeepsTheReplacedTokenForItsWindowOnly() {
        let start = ContinuousClock.now
        var rotation = TokenRotation(overlap: .seconds(30))
        _ = rotation.apply(Self.loaded(Self.old), at: start)
        _ = rotation.apply(Self.loaded(Self.new), at: start + .seconds(5))
        #expect(rotation.accepted.accepts(Self.old.utf8, at: start + .seconds(34)))
        #expect(!rotation.accepted.accepts(Self.old.utf8, at: start + .seconds(35)))
        #expect(rotation.accepted.accepts(Self.new.utf8, at: start + .seconds(35)))
    }

    @Test func rereadingTheSameTokenIsNotARotation() {
        let start = ContinuousClock.now
        var rotation = TokenRotation(overlap: .seconds(30))
        _ = rotation.apply(Self.loaded(Self.old), at: start)
        _ = rotation.apply(Self.loaded(Self.new), at: start)
        let changed3 = rotation.apply(Self.loaded(Self.new + "\n"), at: start + .seconds(20))
        #expect(!changed3)
        #expect(!rotation.accepted.accepts(Self.old.utf8, at: start + .seconds(30)))
        #expect(rotation.accepted.accepts(Self.new.utf8, at: start))
    }

    @Test func noTokenAcceptsNothingAndDropsTheOldOne() {
        let start = ContinuousClock.now
        var rotation = TokenRotation(overlap: .seconds(30))
        _ = rotation.apply(Self.loaded(Self.old), at: start)
        _ = rotation.apply(Self.loaded(Self.new), at: start)
        let changed4 = rotation.apply(nil, at: start + .seconds(1))
        #expect(changed4)
        #expect(!rotation.accepted.accepts(Self.new.utf8, at: start + .seconds(1)))
        #expect(!rotation.accepted.accepts(Self.old.utf8, at: start + .seconds(1)))
        let changed5 = rotation.apply(Self.loaded(Self.new), at: start + .seconds(2))
        #expect(changed5)
        #expect(rotation.accepted.previous == nil)
    }
}

@Suite struct CredentialReloaderTests {
    @Test func startupRefusesAnInvalidPair() async throws {
        let directory = try CredentialDirectory(pair: .wrongCA)
        await #expect(throws: CertificateRejection.notIssuedByCA) {
            _ = try await CredentialReloader(configuration: directory.configuration())
        }
    }

    /// Reviewer repro: opening a FIFO with no writer blocked forever, at startup and in every reload
    /// after it, since reloads run one at a time.
    @Test(.timeLimit(.minutes(1))) func aFIFOAtACredentialPathIsRefusedWithoutBlocking() async throws {
        let directory = try CredentialDirectory()
        try directory.replaceWithFIFO(directory.caPath)
        await #expect(throws: CertificateRejection.unreadable(path: directory.caPath, .notRegularFile)) {
            _ = try await CredentialReloader(configuration: directory.configuration())
        }

        let healthy = try CredentialDirectory()
        let reloader = try await CredentialReloader(configuration: healthy.configuration())
        try healthy.replaceWithFIFO(healthy.keyPath)
        try healthy.replaceWithFIFO(healthy.tokenPath)
        let status = await reloader.reload()
        #expect(status.certificateRejection == .unreadable(path: healthy.keyPath, .notRegularFile))
        #expect(status.tokenRejection == .unreadable(path: healthy.tokenPath, .notRegularFile))

        try healthy.install(.first)
        try healthy.writeToken(CredentialDirectory.firstToken)
        #expect(!(await reloader.reload()).credentialsWarning)
    }

    @Test func startupWithABadTokenFileServesWithNoTokenAndTheWarning() async throws {
        let directory = try CredentialDirectory()
        try directory.setTokenMode(0o644)
        let reloader = try await CredentialReloader(configuration: directory.configuration())
        #expect(
            reloader.status.tokenRejection == .unreadable(path: directory.tokenPath, .accessibleByOthers(mode: 0o644)))
        #expect(reloader.status.credentialsWarning)
        #expect(!reloader.tokens.acceptedTokens().accepts(CredentialDirectory.firstToken.utf8, at: .now))
    }

    @Test(arguments: [
        (RotationPKI.Pair.mismatchedKey, CertificateRejection.keyMismatch),
        (.wrongCA, .notIssuedByCA),
        (.shortLived, .expired),
        (.missingName, .missingServiceName("deskhand-test.forge.svc.cluster.local")),
    ])
    func refusedPairKeepsTheOldOneAndSetsTheWarning(
        _ pair: RotationPKI.Pair, _ expected: CertificateRejection
    ) async throws {
        let directory = try CredentialDirectory()
        let wallClock = ManualClock(CredentialReloader.systemTime())
        let log = CredentialEventLog()
        let reloader = try await CredentialReloader(
            configuration: directory.configuration(), wallClock: { wallClock.now }, events: log.record)
        let original = reloader.tlsContexts.current
        #expect(!reloader.status.credentialsWarning)

        // Two days on, the 30-day pair in use is still in date and the one-day pair is not.
        wallClock.set(wallClock.now.adding(milliseconds: 2 * day))
        try directory.install(pair)
        let status = await reloader.reload()

        #expect(status.certificateRejection == expected)
        #expect(status.credentialsWarning)
        #expect(status.reason == expected.description)
        #expect(reloader.status == status)
        #expect(reloader.tlsContexts.current === original)
        #expect(log.all.contains(.certificateRejected(expected)))

        try directory.install(.second)
        let recovered = await reloader.reload()
        #expect(!recovered.credentialsWarning)
        #expect(reloader.tlsContexts.current !== original)
        #expect(log.all.suffix(2) == [.certificateReplaced, .statusChanged(CredentialStatus())])
    }

    @Test func unchangedFilesDoNotSwapTheContext() async throws {
        let directory = try CredentialDirectory()
        let log = CredentialEventLog()
        let reloader = try await CredentialReloader(configuration: directory.configuration(), events: log.record)
        let original = reloader.tlsContexts.current
        let status = await reloader.reload()
        #expect(!status.credentialsWarning)
        #expect(reloader.tlsContexts.current === original)
        #expect(log.all.isEmpty)
    }

    @Test(arguments: [0, 30])
    func tokenRotationHonoursTheOverlap(_ overlapSeconds: Int) async throws {
        let directory = try CredentialDirectory()
        let start = ContinuousClock.now
        let clock = ManualClock(start)
        let reloader = try await CredentialReloader(
            configuration: directory.configuration(tokenOverlap: .seconds(overlapSeconds)),
            monotonicClock: { clock.now })
        let first = CredentialDirectory.firstToken.utf8
        let second = CredentialDirectory.secondToken.utf8

        clock.set(start + .seconds(100))
        try directory.writeToken(CredentialDirectory.secondToken)
        await reloader.reload()
        let tokens = reloader.tokens.acceptedTokens()
        let switched = start + .seconds(100)
        #expect(tokens.accepts(second, at: switched))
        #expect(tokens.accepts(first, at: switched) == (overlapSeconds > 0))
        #expect(
            tokens.accepts(first, at: switched + .seconds(overlapSeconds) - .milliseconds(1)) == (overlapSeconds > 0))
        #expect(!tokens.accepts(first, at: switched + .seconds(overlapSeconds)))
    }

    @Test func fileWatchPicksUpARotation() async throws {
        let directory = try CredentialDirectory()
        let log = CredentialEventLog()
        let reloader = try await CredentialReloader(configuration: directory.configuration(), events: log.record)
        await reloader.watchFiles(pollInterval: .milliseconds(50))
        defer { Task { await reloader.stop() } }

        try directory.writeToken(CredentialDirectory.secondToken)
        try directory.install(.second)
        #expect(await eventually { log.all.contains(.tokenReplaced) && log.all.contains(.certificateReplaced) })
        #expect(reloader.tokens.acceptedTokens().accepts(CredentialDirectory.secondToken.utf8, at: .now))
        #expect(!reloader.tokens.acceptedTokens().accepts(CredentialDirectory.firstToken.utf8, at: .now))
    }

    @Test func watchRetriesAPairThatWasNotValidYet() async throws {
        let directory = try CredentialDirectory()
        let realTime = CredentialReloader.systemTime()
        let wallClock = ManualClock(realTime)
        let start = ContinuousClock.now
        let clock = ManualClock(start)
        let reloader = try await CredentialReloader(
            configuration: directory.configuration(), wallClock: { wallClock.now }, monotonicClock: { clock.now })
        wallClock.set(realTime.adding(milliseconds: -day))
        try directory.install(.second)
        #expect(await reloader.reload().certificateRejection == .notYetValid)

        await reloader.watchFiles(pollInterval: .milliseconds(20))
        defer { Task { await reloader.stop() } }
        wallClock.set(realTime)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(reloader.status.certificateRejection == .notYetValid)
        clock.set(start + CredentialReloader.notYetValidRetryInterval)
        #expect(await eventually { !reloader.status.credentialsWarning })
    }

    /// Sends a real `SIGHUP` to this process. The signal is repeated until the reload shows,
    /// because libdispatch on Linux may install its handler shortly after `resume()` returns;
    /// until then the signal is ignored, never fatal, since ``CredentialReloader/reloadOnSIGHUP()``
    /// ignores it before returning.
    @Test func sighupReloads() async throws {
        let directory = try CredentialDirectory()
        let log = CredentialEventLog()
        let reloader = try await CredentialReloader(configuration: directory.configuration(), events: log.record)
        await reloader.reloadOnSIGHUP()
        defer { Task { await reloader.stop() } }

        try directory.install(.second)
        let reloaded = await eventually {
            kill(getpid(), SIGHUP)
            try? await Task.sleep(for: .milliseconds(100))
            return log.all.contains(.certificateReplaced)
        }
        #expect(reloaded)
        #expect(!reloader.status.credentialsWarning)
    }
}

@Suite struct CredentialReloadListenerTests {
    private static func withListener(
        _ directory: CredentialDirectory,
        _ body: (SocketAddress, TestPKI, CredentialReloader) async throws -> Void
    ) async throws {
        let pki = try TestPKI.get()
        let reloader = try await CredentialReloader(configuration: directory.configuration())
        let listener = DeskhandListener(
            configuration: ListenerHarness.configuration(),
            tls: reloader.tlsContexts,
            tokens: reloader.tokens,
            handler: RecordingHandler()
        )
        let address = try await listener.start()
        do {
            try await body(address, pki, reloader)
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
    }

    private static func request(token: String) -> TestRequest {
        TestRequest.valid().setting("Authorization", to: "Bearer \(token)")
    }

    @Test func newConnectionsGetTheNewCertificateWhileAnOpenOneKeepsWorking() async throws {
        let directory = try CredentialDirectory()
        let rotation = try RotationPKI.get()
        try await Self.withListener(directory) { address, pki, reloader in
            #expect(try await PresentedCertificate.serialNumber(at: address, pki: pki) == rotation.serialNumber(.first))
            try await TestClient.withConnection(to: address, pki: pki, as: .valid) { connection in
                let token = CredentialDirectory.firstToken
                #expect(await connection.roundTrip(Self.request(token: token)).status == .ok)

                try directory.install(.second)
                #expect(!(await reloader.reload()).credentialsWarning)

                #expect(await connection.roundTrip(Self.request(token: token)).status == .ok)
                #expect(
                    try await PresentedCertificate.serialNumber(at: address, pki: pki)
                        == rotation.serialNumber(.second))
                let fresh = try await TestClient.roundTrip(Self.request(token: token), to: address, pki: pki)
                #expect(fresh.status == .ok)
            }
        }
    }

    @Test func refusedPairLeavesTheOldCertificateServing() async throws {
        let directory = try CredentialDirectory()
        let rotation = try RotationPKI.get()
        try await Self.withListener(directory) { address, pki, reloader in
            try directory.install(.wrongCA)
            #expect(await reloader.reload().certificateRejection == .notIssuedByCA)
            #expect(try await PresentedCertificate.serialNumber(at: address, pki: pki) == rotation.serialNumber(.first))
            let outcome = try await TestClient.roundTrip(
                Self.request(token: CredentialDirectory.firstToken), to: address, pki: pki)
            #expect(outcome.status == .ok)
        }
    }

    @Test func badTokenFileFailsEveryRequestClosedUntilFixed() async throws {
        let directory = try CredentialDirectory()
        try await Self.withListener(directory) { address, pki, reloader in
            let token = CredentialDirectory.firstToken
            #expect(try await TestClient.roundTrip(Self.request(token: token), to: address, pki: pki).status == .ok)

            try directory.setTokenMode(0o644)
            #expect(
                await reloader.reload().tokenRejection
                    == .unreadable(path: directory.tokenPath, .accessibleByOthers(mode: 0o644)))
            #expect(
                try await TestClient.roundTrip(Self.request(token: token), to: address, pki: pki).status
                    == .unauthorized)

            try directory.removeToken()
            #expect(await reloader.reload().tokenRejection == .unreadable(path: directory.tokenPath, .missing))
            #expect(
                try await TestClient.roundTrip(Self.request(token: token), to: address, pki: pki).status
                    == .unauthorized)

            try directory.writeToken("")
            #expect(await reloader.reload().tokenRejection == .malformed(path: directory.tokenPath))
            #expect(
                try await TestClient.roundTrip(Self.request(token: ""), to: address, pki: pki).status
                    == .unauthorized)

            // A file caught half written holds a prefix of the token, which must not become one.
            let prefix = String(token.prefix(LoadedToken.minimumLength - 1))
            try directory.writeToken(prefix)
            #expect(await reloader.reload().tokenRejection == .malformed(path: directory.tokenPath))
            #expect(
                try await TestClient.roundTrip(Self.request(token: prefix), to: address, pki: pki).status
                    == .unauthorized)

            try directory.writeToken(token)
            #expect(!(await reloader.reload()).credentialsWarning)
            #expect(try await TestClient.roundTrip(Self.request(token: token), to: address, pki: pki).status == .ok)
        }
    }

    @Test func zeroOverlapRefusesTheReplacedTokenOnTheNextRequest() async throws {
        let directory = try CredentialDirectory()
        try await Self.withListener(directory) { address, pki, reloader in
            try await TestClient.withConnection(to: address, pki: pki, as: .valid) { connection in
                #expect(await connection.roundTrip(Self.request(token: CredentialDirectory.firstToken)).status == .ok)
                try directory.writeToken(CredentialDirectory.secondToken)
                await reloader.reload()
                #expect(
                    await connection.roundTrip(Self.request(token: CredentialDirectory.firstToken)).status
                        == .unauthorized)
            }
            let outcome = try await TestClient.roundTrip(
                Self.request(token: CredentialDirectory.secondToken), to: address, pki: pki)
            #expect(outcome.status == .ok)
        }
    }
}
