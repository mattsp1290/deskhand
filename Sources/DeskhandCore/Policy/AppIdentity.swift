/// An Apple Developer Program team identifier: exactly 10 characters from `A-Z 0-9`.
public struct TeamID: Hashable, Sendable, CustomStringConvertible {
    public static let length = 10
    public let rawValue: String

    public init?(_ rawValue: String) {
        let bytes = rawValue.utf8
        guard bytes.count == Self.length,
            bytes.allSatisfy({ byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            })
        else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Who signed an app's code, as the platform layer verified it.
public enum CodeSigner: Hashable, Sendable {
    /// A valid signature that carries this team identifier.
    case team(TeamID)
    /// A valid Apple signature (`anchor apple`). Apple's own platform apps carry no team identifier.
    case apple
    /// No signature, an ad hoc signature, or one that does not validate.
    case unsigned
    /// The signature could not be read, or the process was gone before it could be.
    case unknown

    /// `app_ref.team_id` on the wire: the team identifier, or `nil` when there is none.
    public var teamIdentifier: String? {
        guard case .team(let team) = self else { return nil }
        return team.rawValue
    }
}

/// An app as the policy sees it: its bundle identifier plus who signed it (plan, "App-policy boundary").
public struct AppIdentity: Hashable, Sendable {
    /// `nil` when the process has no bundle identifier or it is outside the contract's alphabet.
    public let bundleID: BundleID?
    public let signer: CodeSigner

    /// An app that could not be identified at all, such as the owner of a window that vanished.
    public static let unknown = AppIdentity(bundleID: nil, signer: .unknown)

    public init(bundleID: BundleID?, signer: CodeSigner) {
        self.bundleID = bundleID
        self.signer = signer
    }
}

/// A signer an allowlist entry accepts. Unsigned and unknown signers can never be allowed.
public enum TrustedSigner: Hashable, Sendable {
    case team(TeamID)
    case apple

    func accepts(_ signer: CodeSigner) -> Bool {
        switch (self, signer) {
        case (.team(let expected), .team(let actual)): expected == actual
        case (.apple, .apple): true
        default: false
        }
    }
}

/// One allowlist entry: an exact bundle identifier signed by an exact signer.
public struct AllowedApp: Hashable, Sendable {
    public let bundleID: BundleID
    public let signer: TrustedSigner

    public init(bundleID: BundleID, signer: TrustedSigner) {
        self.bundleID = bundleID
        self.signer = signer
    }
}

/// A bundle identifier together with every identifier nested under it, compared ignoring ASCII case.
///
/// `com.google.Chrome` covers `com.google.Chrome.canary` and `com.google.Chrome.helper` but not
/// `com.google.ChromeRemoteDesktop`. Case is ignored because LaunchServices treats bundle
/// identifiers case-insensitively, and a deny entry must not be dodged by changing case.
public struct BundleIDFamily: Hashable, Sendable, CustomStringConvertible {
    public let root: BundleID
    private let folded: String

    public init(_ root: BundleID) {
        self.root = root
        folded = root.rawValue.lowercased()
    }

    public func contains(_ bundleID: BundleID) -> Bool {
        let candidate = bundleID.rawValue.lowercased()
        return candidate == folded || candidate.hasPrefix(folded + ".")
    }

    public var description: String { root.rawValue }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.folded == rhs.folded }
    public func hash(into hasher: inout Hasher) { hasher.combine(folded) }
}
