/// One app as the platform measured it at an app-policy check (contract 6.9).
public struct ObservedApp: Hashable, Sendable {
    public let identity: AppIdentity
    /// `app_ref.name`.
    public let name: String
    /// `false` when the platform could not be sure who this is: no app, no process, an unreadable
    /// signature. The policy then decides on ``AppIdentity/unknown``, whatever was read.
    public let isCertain: Bool

    public init(identity: AppIdentity, name: String, isCertain: Bool) {
        self.identity = identity
        self.name = name
        self.isCertain = isCertain
    }

    /// Nothing could be determined (contract 6.9: `{"bundle_id": null, "team_id": null, "name": ""}`).
    public static let undetermined = ObservedApp(identity: .unknown, name: "", isCertain: false)

    /// What `measured` reports: what deskhand has, also when it is uncertain.
    public var appRef: AppRef { AppRef(identity, name: name) }

    /// What the policy decides on. Uncertainty refuses (contract 6.9).
    public var policyIdentity: AppIdentity { isCertain ? identity : .unknown }
}

/// A window as measured: the topmost one under a point, or the focused window of the app that owns
/// keyboard focus.
public struct ObservedWindow: Hashable, Sendable {
    /// ``ObservedApp/undetermined`` when no window was found or its owner could not be read.
    public let owner: ObservedApp
    /// Uncut; `nil` when the window has none or it cannot be read. The executor removes it wherever
    /// the contract says a title is not sent (contract 6.7).
    public let title: String?

    public init(owner: ObservedApp, title: String?) {
        self.owner = owner
        self.title = title
    }
}

/// Reads the apps an effect touches, afresh on every call (contract 6.7, 6.9). The executor calls it
/// before admission, at the last look and before every event, with nothing between the last
/// measurement and the post, so it must answer without waiting on anything but the OS.
public protocol IdentityMeasurer: Sendable {
    func frontmostApp() -> ObservedApp

    /// The app that owns keyboard focus (the accessibility focused application) and its focused window.
    func keyboardFocus() -> ObservedWindow

    /// The topmost window under each point, in order, skipping deskhand's indicator and a drag image
    /// (contract 6.9). One answer per point.
    func windows(at points: [GlobalPoint]) -> [ObservedWindow]
}
