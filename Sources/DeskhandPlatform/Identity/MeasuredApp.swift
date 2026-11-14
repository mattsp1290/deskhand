import DeskhandCore
import Foundation

/// Why a measured app's identity cannot be relied on. Every case leaves ``MeasuredApp/identity`` in a
/// shape ``AppPolicy`` refuses, so an uncertain measurement always ends in `denied_app`.
public enum IdentityUncertainty: Hashable, Sendable {
    /// No app is frontmost.
    case noFrontmostApp
    /// Accessibility reports that no app has keyboard focus.
    case noFocusedApp
    /// deskhand is not trusted for Accessibility, so the focus owner cannot be read.
    case accessibilityUntrusted
    /// Accessibility failed with this `AXError` raw value.
    case focusUnreadable(Int32)
    /// The window server gave no window list.
    case windowListUnavailable
    /// No window lies under the point (the desktop, or off every display).
    case noWindow
    /// A window above any hit has no readable frame, so it may cover the point.
    case windowUnreadable
    /// The window has no owning process.
    case noOwnerProcess
    /// The process exited before its code could be read.
    case processGone
    /// The Security framework could not read the code: this `OSStatus`.
    case signatureUnreadable(Int32)
    /// Unsigned, ad hoc signed, not validating, or validly signed without a team or Apple anchor.
    case signatureNotTrusted
    /// A team identifier that is not 10 characters from `A-Z 0-9`.
    case malformedTeamIdentifier
    /// No bundle identifier, or one outside the contract's alphabet.
    case noBundleID
}

/// One app as measured at an app-policy check: what ``AppPolicy`` decides on, plus what `measured`
/// reports (`app_ref`).
public struct MeasuredApp: Hashable, Sendable {
    /// The process, when one was found.
    public let pid: pid_t?
    /// What the policy decides on. ``AppIdentity/unknown`` when no process could be identified.
    public let identity: AppIdentity
    /// `app_ref.name`: the app's display name, else the window server's owner name, else the bundle
    /// identifier, else empty.
    public let name: String
    /// `nil` only when the app has a bundle identifier and a team or Apple signature.
    public let uncertainty: IdentityUncertainty?

    /// An app that could not be identified at all.
    public static func unidentified(_ reason: IdentityUncertainty, pid: pid_t? = nil, name: String? = nil) -> Self {
        Self(pid: pid, identity: .unknown, name: name ?? "", uncertainty: reason)
    }

    /// The app running as `pid`, from what the Security framework said about its code.
    public init(pid: pid_t, signature: CodeSignatureLookup, name: String?) {
        let (signer, signerDoubt) = Self.signer(from: signature)
        let bundleID: BundleID?
        if case .found(let facts) = signature {
            bundleID = Self.bundleID(from: facts, signer: signer)
        } else {
            bundleID = nil
        }
        let doubt = signerDoubt ?? (bundleID == nil ? .noBundleID : nil)
        self.init(
            pid: pid, identity: AppIdentity(bundleID: bundleID, signer: signer),
            name: name ?? bundleID?.rawValue ?? "", uncertainty: doubt)
    }

    private init(pid: pid_t?, identity: AppIdentity, name: String, uncertainty: IdentityUncertainty?) {
        self.pid = pid
        self.identity = identity
        self.name = name
        self.uncertainty = uncertainty
    }

    public var isCertain: Bool { uncertainty == nil }

    /// `app_ref` on the wire.
    public var appRef: AppRef {
        AppRef(bundleID: identity.bundleID?.rawValue, teamID: identity.signer.teamIdentifier, name: name)
    }

    /// Only Apple's own code satisfies `anchor apple`, and the allowlist names such apps as `apple`, so
    /// the anchor is checked before any team identifier the signature may also carry.
    static func signer(from lookup: CodeSignatureLookup) -> (CodeSigner, IdentityUncertainty?) {
        switch lookup {
        case .processGone: return (.unknown, .processGone)
        case .unreadable(let status): return (.unknown, .signatureUnreadable(status))
        case .found(let facts):
            guard facts.validity == .valid, !facts.isAdHoc else { return (.unsigned, .signatureNotTrusted) }
            if facts.satisfiesAppleAnchor { return (.apple, nil) }
            guard let raw = facts.teamIdentifier else { return (.unsigned, .signatureNotTrusted) }
            guard let team = TeamID(raw) else { return (.unknown, .malformedTeamIdentifier) }
            return (.team(team), nil)
        }
    }

    /// A trusted signer vouches only for the Info.plist bound into its signature; the bundle on disk
    /// is consulted only to name an app the policy will refuse anyway.
    static func bundleID(from facts: CodeSignatureFacts, signer: CodeSigner) -> BundleID? {
        let raw: String?
        switch signer {
        case .team, .apple: raw = facts.sealedBundleIdentifier
        case .unsigned, .unknown: raw = facts.sealedBundleIdentifier ?? facts.bundleIdentifierAtPath
        }
        return raw.flatMap(BundleID.init)
    }
}
