import DeskhandCore
import Synchronization

/// Why the token file yielded no token (contract 11.1). The old token is not kept: every request
/// gets `401` until the file is fixed (Appendix A item 31).
public enum TokenRejection: Error, Hashable, Sendable, CustomStringConvertible {
    case unreadable(path: String, CredentialFileError)
    /// Shorter than ``LoadedToken/minimumLength``, or a byte that cannot appear in a `Bearer`
    /// credential.
    case malformed(path: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let error): "\(path): \(error)"
        case .malformed(let path):
            "\(path): not a token (one line of at least \(LoadedToken.minimumLength) visible ASCII characters)"
        }
    }
}

struct LoadedToken {
    static let minimumLength = 32

    let token: BearerToken
    let digest: SHA256Hex

    static func parse(_ contents: [UInt8]) -> LoadedToken? {
        var secret = contents[...]
        if secret.last == UInt8(ascii: "\n") { secret = secret.dropLast() }
        if secret.last == UInt8(ascii: "\r") { secret = secret.dropLast() }
        guard secret.count >= minimumLength, secret.allSatisfy({ (0x21...0x7E).contains($0) }),
            let token = BearerToken(secret: secret)
        else { return nil }
        return LoadedToken(token: token, digest: SHA256Hex(hashing: secret))
    }

    static func load(path: String) -> Result<LoadedToken, TokenRejection> {
        let contents: [UInt8]
        do {
            contents = try CredentialFile.read(path: path)
        } catch {
            return .failure(.unreadable(path: path, error))
        }
        guard let loaded = parse(contents) else { return .failure(.malformed(path: path)) }
        return .success(loaded)
    }
}

struct TokenRotation {
    private(set) var accepted = AcceptedTokens.none
    private var currentDigest: SHA256Hex?
    let overlap: Duration

    init(overlap: Duration) {
        self.overlap = overlap
    }

    mutating func apply(_ loaded: LoadedToken?, at now: ContinuousClock.Instant) -> Bool {
        guard let loaded else {
            let changed = currentDigest != nil || accepted.previous != nil
            accepted = .none
            currentDigest = nil
            return changed
        }
        guard loaded.digest != currentDigest else { return false }
        let retired = accepted.current.flatMap { current in
            overlap > .zero ? AcceptedTokens.Retired(token: current, acceptedUntil: now + overlap) : nil
        }
        accepted = AcceptedTokens(current: loaded.token, previous: retired)
        currentDigest = loaded.digest
        return true
    }
}

/// The ``TokenProvider`` the listener reads on every request; the ``CredentialReloader`` swaps
/// the set behind a lock, so a read never waits on a reload.
public final class ReloadingTokenProvider: TokenProvider {
    private let tokens = Mutex(AcceptedTokens.none)

    init() {}

    public func acceptedTokens() -> AcceptedTokens { tokens.withLock { $0 } }

    func replace(with accepted: AcceptedTokens) {
        tokens.withLock { $0 = accepted }
    }
}
