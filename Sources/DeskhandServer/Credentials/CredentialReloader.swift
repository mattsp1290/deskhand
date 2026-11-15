import DeskhandCore
import Dispatch
import NIOCore
import NIOPosix
import NIOSSL
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The files and names credential reload works from. Production builds it from ``DeskhandConfig``.
public struct CredentialReloadConfiguration: Hashable, Sendable {
    public var caCertificatePath: String
    public var serverCertificatePath: String
    public var serverKeyPath: String
    public var tokenPath: String
    /// Every one must be a subject alternative name of a new server certificate.
    public var serviceNames: [String]
    /// How long a replaced token is still accepted; zero revokes it at once.
    public var tokenOverlap: Duration

    public init(
        caCertificatePath: String,
        serverCertificatePath: String,
        serverKeyPath: String,
        tokenPath: String,
        serviceNames: [String],
        tokenOverlap: Duration = .zero
    ) {
        self.caCertificatePath = caCertificatePath
        self.serverCertificatePath = serverCertificatePath
        self.serverKeyPath = serverKeyPath
        self.tokenPath = tokenPath
        self.serviceNames = serviceNames
        self.tokenOverlap = tokenOverlap
    }

    public init(config: DeskhandConfig) {
        self.init(
            caCertificatePath: config.credentials.caCertificatePath,
            serverCertificatePath: config.credentials.serverCertificatePath,
            serverKeyPath: config.credentials.serverKeyPath,
            tokenPath: config.credentials.tokenPath,
            serviceNames: config.service.names,
            tokenOverlap: .milliseconds(config.credentials.tokenOverlapMs)
        )
    }

    var watchedPaths: [String] { [caCertificatePath, serverCertificatePath, serverKeyPath, tokenPath] }
}

/// The `credentials_warning` condition (contract 11.1) and why it is set. Each reason is cleared
/// by the next reload whose own check passes.
public struct CredentialStatus: Hashable, Sendable {
    /// The last server certificate and key read were refused; the previous pair is still in use.
    public let certificateRejection: CertificateRejection?
    /// The token file yields no token; every request gets `401`.
    public let tokenRejection: TokenRejection?

    public init(certificateRejection: CertificateRejection? = nil, tokenRejection: TokenRejection? = nil) {
        self.certificateRejection = certificateRejection
        self.tokenRejection = tokenRejection
    }

    public var credentialsWarning: Bool { certificateRejection != nil || tokenRejection != nil }

    /// For the log: the reasons, never a credential.
    public var reason: String? {
        let reasons = [certificateRejection?.description, tokenRejection?.description].compactMap { $0 }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }
}

/// What a reload did, for the log. Never carries a credential.
public enum CredentialEvent: Hashable, Sendable {
    case certificateReplaced
    case certificateRejected(CertificateRejection)
    case tokenReplaced
    case tokenRejected(TokenRejection)
    case statusChanged(CredentialStatus)
}

/// Reloads the server certificate, key and bearer token (contract 11.1) when their files change
/// and on `SIGHUP`, and owns what the listener reads: ``tlsContexts`` for new connections and
/// ``tokens`` for every request.
///
/// A server pair replaces the one in use only after ``ServerPairValidator`` accepts it; a refused
/// pair leaves the old one serving and sets ``status``. A token file that yields no token is not
/// treated that way: no token is accepted until the file is fixed. Reloads run one at a time, in
/// the order they were asked for.
public actor CredentialReloader {
    public nonisolated let tlsContexts: ServerTLSContextHolder
    public nonisolated let tokens: ReloadingTokenProvider

    private let configuration: CredentialReloadConfiguration
    private let group: any EventLoopGroup
    private let wallClock: @Sendable () -> Timestamp
    private let monotonicClock: @Sendable () -> ContinuousClock.Instant
    private let events: @Sendable (CredentialEvent) -> Void
    private nonisolated let published: Mutex<CredentialStatus>

    private var activeFingerprint: SHA256Hex
    private var tokenRotation: TokenRotation
    private var reloadInFlight: Task<CredentialStatus, Never>?
    private var watcher: Task<Void, Never>?
    private var lastSignatures: [FileSignature?]
    private var changePending = false
    private var lastReload: ContinuousClock.Instant
    private nonisolated let hangup = HangupSignalSource()

    /// Validates the server pair and reads the token. A refused pair is thrown, since there is no
    /// previous one to keep; a token file that yields no token starts the service with no token
    /// accepted and the warning set, so fixing the file brings it back without a restart.
    ///
    /// `wallClock` decides whether a certificate is in date; `monotonicClock` times the token
    /// overlap window.
    public init(
        configuration: CredentialReloadConfiguration,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        wallClock: @escaping @Sendable () -> Timestamp = CredentialReloader.systemTime,
        monotonicClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        events: @escaping @Sendable (CredentialEvent) -> Void = { _ in }
    ) async throws(CertificateRejection) {
        let signatures = configuration.watchedPaths.map(FileSignature.of(path:))
        let (accepted, fingerprint) = try await Self.loadServerPair(
            configuration, group: group, now: wallClock()
        ).get()
        var rotation = TokenRotation(overlap: configuration.tokenOverlap)
        let token = LoadedToken.load(path: configuration.tokenPath)
        _ = rotation.apply(try? token.get(), at: monotonicClock())
        let tokens = ReloadingTokenProvider()
        tokens.replace(with: rotation.accepted)

        self.configuration = configuration
        self.group = group
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.events = events
        self.tlsContexts = ServerTLSContextHolder(accepted.context)
        self.tokens = tokens
        self.activeFingerprint = fingerprint
        self.tokenRotation = rotation
        self.lastSignatures = signatures
        self.lastReload = monotonicClock()
        let tokenRejection: TokenRejection?
        if case .failure(let rejection) = token {
            tokenRejection = rejection
            events(.tokenRejected(rejection))
        } else {
            tokenRejection = nil
        }
        self.published = Mutex(CredentialStatus(tokenRejection: tokenRejection))
    }

    deinit {
        watcher?.cancel()
        hangup.cancel()
    }

    public nonisolated var status: CredentialStatus { published.withLock { $0 } }

    /// Reads and checks every credential file now. ``watchFiles(pollInterval:)`` and
    /// ``reloadOnSIGHUP()`` call this too.
    @discardableResult
    public func reload() async -> CredentialStatus {
        let previous = reloadInFlight
        let next = Task {
            _ = await previous?.value
            return await self.performReload()
        }
        reloadInFlight = next
        return await next.value
    }

    /// Polls the four credential files every `pollInterval` and reloads once a change has held
    /// still for one interval, so a certificate and key written one after the other are read
    /// together. See ``FileSignature`` for why this polls on both platforms. A pair refused as not
    /// valid yet is retried every ``notYetValidRetryInterval`` while the watch runs.
    public func watchFiles(pollInterval: Duration = .seconds(1)) {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard let self, !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }

    /// Reloads on every `SIGHUP`. The signal's default action, ending the process, is turned off
    /// for the whole process and stays off after ``stop()``.
    public func reloadOnSIGHUP() {
        hangup.install { [weak self] in
            guard let self else { return }
            Task { await self.reload() }
        }
    }

    /// Stops watching files and handling `SIGHUP`. What is loaded stays in use.
    public func stop() {
        watcher?.cancel()
        watcher = nil
        hangup.cancel()
    }

    public static let systemTime: @Sendable () -> Timestamp = {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return Timestamp(millisecondsSinceEpoch: Int64(now.tv_sec) * 1000 + Int64(now.tv_nsec) / 1_000_000)
    }

    private func poll() async {
        let signatures = configuration.watchedPaths.map(FileSignature.of(path:))
        if signatures != lastSignatures {
            lastSignatures = signatures
            changePending = true
            return
        }
        if changePending {
            changePending = false
            await reload()
        } else if status.certificateRejection == .notYetValid,
            monotonicClock() - lastReload >= Self.notYetValidRetryInterval
        {
            await reload()
        }
    }

    static let notYetValidRetryInterval = Duration.seconds(10)

    private func performReload() async -> CredentialStatus {
        lastReload = monotonicClock()
        lastSignatures = configuration.watchedPaths.map(FileSignature.of(path:))
        changePending = false
        let certificateRejection: CertificateRejection?
        switch await Self.loadServerPair(configuration, group: group, now: wallClock()) {
        case .success(let (accepted, fingerprint)):
            certificateRejection = nil
            if fingerprint != activeFingerprint {
                tlsContexts.replace(with: accepted.context)
                activeFingerprint = fingerprint
                events(.certificateReplaced)
            }
        case .failure(let rejection):
            certificateRejection = rejection
            events(.certificateRejected(rejection))
        }

        let token = LoadedToken.load(path: configuration.tokenPath)
        let tokenChanged = tokenRotation.apply(try? token.get(), at: monotonicClock())
        if tokenChanged { tokens.replace(with: tokenRotation.accepted) }
        let tokenRejection: TokenRejection?
        switch token {
        case .success:
            tokenRejection = nil
            if tokenChanged { events(.tokenReplaced) }
        case .failure(let rejection):
            tokenRejection = rejection
            events(.tokenRejected(rejection))
        }

        let status = CredentialStatus(certificateRejection: certificateRejection, tokenRejection: tokenRejection)
        let changed = published.withLock { published in
            defer { published = status }
            return published != status
        }
        if changed { events(.statusChanged(status)) }
        return status
    }

    private static func loadServerPair(
        _ configuration: CredentialReloadConfiguration,
        group: any EventLoopGroup,
        now: Timestamp
    ) async -> Result<(ServerPairValidator.Accepted, SHA256Hex), CertificateRejection> {
        let paths = [configuration.caCertificatePath, configuration.serverCertificatePath, configuration.serverKeyPath]
        var files: [[UInt8]] = []
        for path in paths {
            do {
                files.append(try CredentialFile.read(path: path))
            } catch {
                return .failure(.unreadable(path: path, error))
            }
        }
        let credentials: ServerTLSCredentials
        do {
            credentials = try ServerTLSCredentials(caPEM: files[0], certificatePEM: files[1], keyPEM: files[2])
        } catch {
            return .failure(.unparseable(error.description))
        }
        let fingerprint = SHA256Hex(
            hashing: files.flatMap { file in withUnsafeBytes(of: UInt64(file.count).bigEndian, Array.init) + file }
        )
        return await ServerPairValidator.validate(
            credentials, serviceNames: configuration.serviceNames, now: now, group: group
        )
        .map { ($0, fingerprint) }
    }
}

private final class HangupSignalSource: Sendable {
    private let source = Mutex<(any DispatchSourceSignal)?>(nil)

    func install(_ handler: @escaping @Sendable () -> Void) {
        source.withLock { source in
            guard source == nil else { return }
            signal(SIGHUP, SIG_IGN)
            let created = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
            created.setEventHandler(handler: handler)
            created.resume()
            source = created
        }
    }

    func cancel() {
        source.withLock { source in
            source?.cancel()
            source = nil
        }
    }
}
