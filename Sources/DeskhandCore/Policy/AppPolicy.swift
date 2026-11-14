/// The apps an effect touches, as measured at one app-policy check (contract 6.8).
public enum EffectTarget: Hashable, Sendable {
    /// `keyboard`: only the frontmost app is checked.
    case keyboard
    /// `pointer`: the owner of the topmost window under each checked point, in point order (the target;
    /// for `drag`, the first and the last point). A window whose owner could not be read is
    /// ``AppIdentity/unknown``. An empty list is refused, since nothing under the pointer was checked.
    case pointer(windowOwners: [AppIdentity])
}

/// Which measured app a refusal is about.
public enum PolicySubject: Hashable, Sendable {
    case frontmost
    /// The window owner at this index of ``EffectTarget/pointer(windowOwners:)``.
    case windowOwner(index: Int)
    /// A `pointer` check with no window owners at all.
    case pointerTarget
}

/// Why one app is refused.
public enum AppDenialReason: Hashable, Sendable {
    /// The app has no usable bundle identifier, or nothing could be identified.
    case unidentified
    /// The app is on the deny list. The deny list wins over the allowlist.
    case denyListed(BundleIDFamily)
    /// The app is unsigned, ad hoc signed, or its signature does not validate.
    case unsigned
    /// The signature could not be read, so the app's identity is uncertain.
    case signerUnknown
    /// No allowlist entry names the bundle identifier.
    case notAllowlisted
    /// The allowlist names the bundle identifier, but for a different signer.
    case signerMismatch
    /// Allowed by the Mac's policy but missing from the call's `permitted_apps`.
    case notInPermittedApps
}

/// A `denied_app` refusal before the caller attaches `measured`.
public struct AppDenial: Hashable, Sendable {
    public let deniedBy: DeniedBy
    public let subject: PolicySubject
    public let reason: AppDenialReason

    public init(deniedBy: DeniedBy, subject: PolicySubject, reason: AppDenialReason) {
        self.deniedBy = deniedBy
        self.subject = subject
        self.reason = reason
    }

    public func toolErrorReason(measured: Measured) -> ToolErrorReason { .deniedApp(deniedBy, measured: measured) }
}

public enum AppDecision: Hashable, Sendable {
    case allow
    case deny(AppDenial)
}

public enum ChordDecision: Hashable, Sendable {
    case allow
    case deny(Chord)

    /// `denied_shortcut` with `details.shortcut`, or `nil` when the chord is allowed.
    public var toolErrorReason: ToolErrorReason? {
        guard case .deny(let chord) = self else { return nil }
        return .deniedShortcut(shortcut: chord.shortcut)
    }
}

/// The per-Mac app policy (plan, "App-policy boundary"): deny by default, an allowlist of exact
/// (bundle identifier, signer) pairs, a deny list that wins over it, denied global shortcuts, and the
/// apps left out of screenshots. A plain value: decisions are pure, and the owner of the configuration
/// swaps the whole value when it changes.
public struct AppPolicy: Hashable, Sendable {
    public var allowed: Set<AllowedApp>
    public var denied: Set<BundleIDFamily>
    public var deniedChords: Set<Chord>
    public var captureExclusions: Set<BundleIDFamily>

    public static let defaultDenied = Set(DefaultDenyEntry.all.map(\.family))
    public static let defaultDeniedChords = Set(DeniedChordEntry.all.map(\.chord))
    public static let defaultCaptureExclusions = Set(
        DefaultDenyEntry.all.filter(\.category.excludedFromCaptureByDefault).map(\.family))

    public init(
        allowed: Set<AllowedApp> = [], denied: Set<BundleIDFamily> = Self.defaultDenied,
        deniedChords: Set<Chord> = Self.defaultDeniedChords,
        captureExclusions: Set<BundleIDFamily> = Self.defaultCaptureExclusions
    ) {
        self.allowed = allowed
        self.denied = denied
        self.deniedChords = deniedChords
        self.captureExclusions = captureExclusions
    }

    /// Why the Mac's policy refuses `app`, or `nil` when it allows it.
    public func refusal(of app: AppIdentity) -> AppDenialReason? {
        guard let bundleID = app.bundleID else { return .unidentified }
        if let family = denied.first(where: { $0.contains(bundleID) }) { return .denyListed(family) }
        switch app.signer {
        case .unknown: return .signerUnknown
        case .unsigned: return .unsigned
        case .team, .apple: break
        }
        let entries = allowed.filter { $0.bundleID == bundleID }
        if entries.isEmpty { return .notAllowlisted }
        return entries.contains { $0.signer.accepts(app.signer) } ? nil : .signerMismatch
    }

    /// The app-policy check run before every posted event (contract 6.8, 9.5 step 14). The Mac's policy
    /// is applied to every measured app before `permittedApps`, so `denied_by` is `policy` whenever the
    /// Mac itself refuses; `permitted_apps` can only narrow.
    public func evaluate(frontmost: AppIdentity, target: EffectTarget, permittedApps: Set<BundleID>?) -> AppDecision {
        var subjects: [(PolicySubject, AppIdentity)] = [(.frontmost, frontmost)]
        if case .pointer(let owners) = target {
            guard !owners.isEmpty else {
                return .deny(AppDenial(deniedBy: .policy, subject: .pointerTarget, reason: .unidentified))
            }
            subjects += owners.enumerated().map { (.windowOwner(index: $0.offset), $0.element) }
        }
        for (subject, app) in subjects {
            if let reason = refusal(of: app) {
                return .deny(AppDenial(deniedBy: .policy, subject: subject, reason: reason))
            }
        }
        if let permittedApps {
            for (subject, app) in subjects where !(app.bundleID.map(permittedApps.contains) ?? false) {
                return .deny(AppDenial(deniedBy: .permittedApps, subject: subject, reason: .notInPermittedApps))
            }
        }
        return .allow
    }

    /// Whether a `keyboard` `press` is a denied global shortcut (contract 6.5, 9.5 step 12).
    public func evaluate(chord: Chord) -> ChordDecision {
        deniedChords.contains(chord) ? .deny(chord) : .allow
    }

    /// Whether screenshots leave out the windows of an app with this bundle identifier.
    public func excludesFromCapture(_ bundleID: BundleID) -> Bool {
        captureExclusions.contains { $0.contains(bundleID) }
    }
}
