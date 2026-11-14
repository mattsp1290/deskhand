import DeskhandCore

/// A bearer token as deskhand holds it: only its SHA-256, so the secret itself is not kept in
/// memory and can never reach a log through this value.
public struct BearerToken: Sendable, CustomStringConvertible {
    fileprivate let digest: SHA256Hex

    /// Nil for an empty secret, which would otherwise match an empty `Bearer` credential.
    public init?(secret: some Collection<UInt8>) {
        guard !secret.isEmpty else { return nil }
        digest = SHA256Hex(hashing: secret)
    }

    public var description: String { "BearerToken(redacted)" }
}

/// The tokens a request may present at one moment (contract 11.1): the current token and, during
/// a configured overlap window after a rotation, the one it replaced.
public struct AcceptedTokens: Sendable {
    public struct Retired: Sendable {
        public let token: BearerToken
        /// The previous token is refused from this instant on.
        public let acceptedUntil: ContinuousClock.Instant

        public init(token: BearerToken, acceptedUntil: ContinuousClock.Instant) {
            self.token = token
            self.acceptedUntil = acceptedUntil
        }
    }

    /// Nil while the token file is missing or malformed: then nothing is accepted.
    public let current: BearerToken?
    public let previous: Retired?

    public init(current: BearerToken?, previous: Retired? = nil) {
        self.current = current
        self.previous = previous
    }

    public static let none = AcceptedTokens(current: nil)

    /// Compares in constant time: both candidates are always compared, over fixed-length digests,
    /// so neither the token's length nor which candidate matched shows in the timing.
    public func accepts(_ presented: some Collection<UInt8>, at now: ContinuousClock.Instant) -> Bool {
        let presentedDigest = SHA256Hex(hashing: presented).bytes
        let matchesCurrent = current.map { Self.equal($0.digest.bytes, presentedDigest) } ?? false
        let matchesPrevious = previous.map { Self.equal($0.token.digest.bytes, presentedDigest) } ?? false
        let previousLive = previous.map { now < $0.acceptedUntil } ?? false
        return matchesCurrent || (matchesPrevious && previousLive)
    }

    private static func equal(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

/// Supplies the bearer tokens the listener accepts. deskhand-zkt0 implements it over the token
/// file with reload; the listener only enforces `401`.
///
/// Called once per request on a NIO event loop, so it must return without blocking: hold the
/// current set behind a lock and swap it on reload.
public protocol TokenProvider: Sendable {
    func acceptedTokens() -> AcceptedTokens
}
