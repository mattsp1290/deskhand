/// The owner of the topmost window under one checked point of a `pointer` action.
public struct WindowOwner: Hashable, Sendable {
    /// `details.point_index`: the point of the action this check belongs to (contract 6.9).
    public let pointIndex: Int
    /// ``AppIdentity/unknown`` when no window was found or its owner could not be read.
    public let app: AppIdentity

    public init(pointIndex: Int, app: AppIdentity) {
        self.pointIndex = pointIndex
        self.app = app
    }
}

/// The apps an effect touches besides the frontmost app, as measured at one app-policy check
/// (contract 6.9, "What is checked").
public enum EffectTarget: Hashable, Sendable {
    /// `keyboard`: the app that owns keyboard focus, ``AppIdentity/unknown`` when it cannot be read.
    case keyboard(focusOwner: AppIdentity)
    /// `pointer`: the owner of the topmost window under each checked point, in order. For `drag`
    /// every sample of ``PointerAction/policySamples``. An empty list is refused, since nothing
    /// under the pointer was checked.
    case pointer(windowOwners: [WindowOwner])
}

/// Which measured app a refusal is about.
public enum PolicySubject: Hashable, Sendable {
    case frontmost
    case keyboardFocus
    case windowOwner(pointIndex: Int)
    /// A `pointer` check with no window owners at all.
    case pointerTarget

    /// `details.point_index`: absent when the refusal did not come from a point (contract 6.9).
    public var pointIndex: Int? {
        switch self {
        case .frontmost, .keyboardFocus: nil
        case .windowOwner(let index): index
        case .pointerTarget: 0
        }
    }
}

/// Why one app is refused.
public enum AppDenialReason: Hashable, Sendable {
    /// deskhand's own bundle, which is never allowed whatever the configuration says.
    case deskhandItself
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

    /// `denied_app` with `measured` (its window titles removed) and `details.point_index`.
    public func toolErrorReason(measured: Measured) -> ToolErrorReason {
        .deniedApp(deniedBy, measured: measured, pointIndex: subject.pointIndex)
    }
}

public enum AppDecision: Hashable, Sendable {
    case allow
    case deny(AppDenial)
}

public enum ChordDecision: Hashable, Sendable {
    case allow
    /// The press as it was sent, which is what `details.shortcut` names.
    case deny(Chord)

    /// `denied_shortcut` with `details.shortcut`, or `nil` when the chord is allowed.
    public var toolErrorReason: ToolErrorReason? {
        guard case .deny(let chord) = self else { return nil }
        return .deniedShortcut(shortcut: chord.shortcut)
    }
}

/// The per-Mac app policy (contract 6.9): deny by default, an allowlist of exact (bundle identifier,
/// signer) pairs, a deny list that wins over it, deskhand's own bundle denied above everything,
/// denied global shortcuts, and the apps left out of screenshots. A plain value: decisions are pure,
/// and the owner of the configuration swaps the whole value when it changes.
public struct AppPolicy: Hashable, Sendable {
    /// deskhand's own bundle and every identifier nested under it. Never allowed, never captured.
    public let deskhand: BundleIDFamily
    public var allowed: Set<AllowedApp>
    public var denied: Set<BundleIDFamily>
    public var deniedChords: Set<Chord>
    public var captureExclusions: Set<BundleIDFamily>

    public static let defaultDenied = Set(DefaultDenyEntry.all.map(\.family))
    public static let defaultDeniedChords = Set(DeniedChordEntry.all.map(\.chord))
    public static let defaultCaptureExclusions = Set(
        DefaultDenyEntry.all.filter(\.category.excludedFromCaptureByDefault).map(\.family))

    /// - Parameter deskhandBundleID: the running deskhand's own bundle identifier, from the app.
    public init(
        deskhandBundleID: BundleID, allowed: Set<AllowedApp> = [], denied: Set<BundleIDFamily> = Self.defaultDenied,
        deniedChords: Set<Chord> = Self.defaultDeniedChords,
        captureExclusions: Set<BundleIDFamily> = Self.defaultCaptureExclusions
    ) {
        deskhand = BundleIDFamily(deskhandBundleID)
        self.allowed = allowed
        self.denied = denied
        self.deniedChords = deniedChords
        self.captureExclusions = captureExclusions
    }

    /// Why the Mac's policy refuses `app`, or `nil` when it allows it.
    public func refusal(of app: AppIdentity) -> AppDenialReason? {
        guard let bundleID = app.bundleID else { return .unidentified }
        if deskhand.contains(bundleID) { return .deskhandItself }
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

    /// The app-policy check run before admission and before every posted event (contract 6.8, 6.9,
    /// 9.5 step 14). The Mac's policy is applied to every measured app before `permittedApps`, so
    /// `denied_by` is `policy` whenever the Mac itself refuses; `permitted_apps` can only narrow.
    public func evaluate(frontmost: AppIdentity, target: EffectTarget, permittedApps: Set<BundleID>?) -> AppDecision {
        var subjects: [(PolicySubject, AppIdentity)] = [(.frontmost, frontmost)]
        switch target {
        case .keyboard(let focusOwner):
            subjects.append((.keyboardFocus, focusOwner))
        case .pointer(let owners):
            guard !owners.isEmpty else {
                return .deny(AppDenial(deniedBy: .policy, subject: .pointerTarget, reason: .unidentified))
            }
            subjects += owners.map { (.windowOwner(pointIndex: $0.pointIndex), $0.app) }
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

    /// Whether a `keyboard` `press` is a denied global shortcut (contract 6.5, 6.9, 9.5 step 12). A
    /// press is denied when its key equals an entry's key and its modifiers include all of the
    /// entry's: `shift+command+tab` is denied by `command+tab`, and `f11` with any modifiers by
    /// `f11`. This fails closed; it can refuse a harmless chord, never let a listed one through.
    public func evaluate(chord: Chord) -> ChordDecision {
        let denied = deniedChords.contains { $0.key == chord.key && $0.modifiers.isSubset(of: chord.modifiers) }
        return denied ? .deny(chord) : .allow
    }

    /// Whether screenshots leave out the windows of an app with this bundle identifier. deskhand's
    /// own windows are always left out (contract 6.9).
    public func excludesFromCapture(_ bundleID: BundleID) -> Bool {
        deskhand.contains(bundleID) || captureExclusions.contains { $0.contains(bundleID) }
    }
}

extension PointerAction {
    /// The points whose window owner the app policy checks before admission, each with the
    /// `details.point_index` a refusal there reports (contract 6.9). `move`, `click` and `scroll`
    /// check their target, index 0. A `drag` checks every point of its path and samples every
    /// segment so that consecutive samples are at most `DRAG_POLICY_SAMPLE_PX` apart after rounding
    /// to whole frame pixels; a sample takes the index of the point that ends its segment. The
    /// executor moves the pointer through the same samples, checking each before it moves there.
    public var policySamples: [(pointIndex: Int, point: FramePoint)] {
        guard case .drag(let drag) = self else { return [(0, points[0])] }
        // Rounding moves each end of a step by at most half a pixel per axis, so a step of
        // `limit - sqrt(2)` stays within `limit` once rounded.
        let step = Double(ContractConstants.dragPolicySamplePx) - 2.0.squareRoot()
        var samples = [(pointIndex: 0, point: drag.path[0])]
        for index in drag.path.indices.dropFirst() {
            let from = drag.path[index - 1]
            let to = drag.path[index]
            let dx = Double(to.x - from.x)
            let dy = Double(to.y - from.y)
            let count = max(1, Int(((dx * dx + dy * dy).squareRoot() / step).rounded(.up)))
            for part in 1...count {
                let fraction = Double(part) / Double(count)
                let point = FramePoint(
                    x: from.x + Int((dx * fraction).rounded()), y: from.y + Int((dy * fraction).rounded()))
                samples.append((index, point))
            }
        }
        return samples
    }
}
