import DeskhandCore
import Foundation

/// The OS queries app identity is measured from. ``LiveIdentitySystem`` asks the window server,
/// Accessibility and Security frameworks; tests substitute a fake so ``IdentityProbe``'s rules run
/// under plain `swift test`. Every query is a fresh read: nothing is cached between calls. The one
/// exception is ``frontmostProcess()``, which is only as fresh as the main run loop.
public protocol IdentitySystem: Sendable {
    /// The current time on the clock the kernel records process start times on. A process whose start
    /// time is later than a reading taken before its pid was obtained is not the process the pid named.
    func wallClock() -> ProcessStartTime
    /// The on-screen windows, front to back, or `nil` when the window server gave no list.
    func onScreenWindows() -> [IdentityWindowEntry]?
    /// The process of the frontmost app, or `nil` when there is none. AppKit updates this as the main
    /// run loop turns, so it can be stale while the main thread is busy and never changes in a process
    /// without one; ``IdentityProbe/frontmostApp()`` therefore confirms it with ``activation(of:)``.
    func frontmostProcess() -> pid_t?
    /// Whether the process reports itself as the active app, as Accessibility reads it from that app.
    /// Unlike ``focusedApplication()``, this stays true while a non-activating panel of another process
    /// holds keyboard focus.
    func activation(of pid: pid_t) -> ActivationLookup
    /// The process that owns keyboard focus, as Accessibility reports it.
    func focusedApplication() -> FocusedApplicationLookup
    /// The code signature of a running process.
    func codeSignature(of pid: pid_t) -> CodeSignatureLookup
    /// The process's user-visible app name, or `nil` when it has none.
    func localizedName(of pid: pid_t) -> String?
    /// The title of the process's focused window, uncut, or `nil` when it cannot be read.
    func focusedWindowTitle(of pid: pid_t) -> String?
    /// When the process now running as `pid` started, or `nil` when no process has that pid. Two reads
    /// that differ mean the pid now belongs to another process.
    func processStartTime(of pid: pid_t) -> ProcessStartTime?
}

/// A process's start time as the kernel records it. With the pid, it names one process: a pid is reused
/// only by a process that starts later.
public struct ProcessStartTime: Hashable, Comparable, Sendable {
    public var seconds: Int64
    public var microseconds: Int32

    public init(seconds: Int64, microseconds: Int32) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.seconds, lhs.microseconds) < (rhs.seconds, rhs.microseconds)
    }
}

/// One window from the window server's on-screen list. A `nil` member could not be read.
public struct IdentityWindowEntry: Hashable, Sendable {
    public var windowNumber: UInt32?
    public var ownerPID: pid_t?
    public var ownerName: String?
    /// The window level. 0 is the normal level; the menu bar, status items and the Dock sit above it.
    public var layer: Int?
    /// The window's frame in global points: origin at the top-left of the main display, y down.
    public var bounds: GlobalRect?
    /// The window's title, uncut. The window server withholds it without the Screen Recording grant.
    public var title: String?

    public init(
        windowNumber: UInt32? = nil, ownerPID: pid_t?, ownerName: String? = nil, layer: Int?, bounds: GlobalRect?,
        title: String? = nil
    ) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
        self.bounds = bounds
        self.title = title
    }
}

public enum FocusedApplicationLookup: Hashable, Sendable {
    case process(pid_t)
    /// Accessibility answered that no app has keyboard focus.
    case noFocus
    /// deskhand is not trusted for Accessibility, so focus cannot be read.
    case accessibilityUntrusted
    /// Accessibility returned this `AXError` raw value.
    case failed(Int32)
}

public enum ActivationLookup: Hashable, Sendable {
    case active
    case inactive
    /// deskhand is not trusted for Accessibility, so activation cannot be read.
    case accessibilityUntrusted
    /// Accessibility returned this `AXError` raw value.
    case failed(Int32)
}

public enum CodeSignatureLookup: Hashable, Sendable {
    case found(CodeSignatureFacts)
    /// The process exited before its code could be read.
    case processGone
    /// The Security framework returned this `OSStatus`.
    case unreadable(Int32)
}

/// What the Security framework reported about a running process's code.
public struct CodeSignatureFacts: Hashable, Sendable {
    public enum Validity: Hashable, Sendable {
        /// The running code validated against its own designated requirement.
        case valid
        /// The code carries no signature.
        case unsigned
        /// A signature is present but the code does not validate against it.
        case invalid
    }

    public var validity: Validity
    /// The signature is ad hoc: no certificate, so no signer.
    public var isAdHoc: Bool
    /// The code satisfies the requirement `anchor apple`, which only Apple's own code does.
    public var satisfiesAppleAnchor: Bool
    /// `kSecCodeInfoTeamIdentifier`, verbatim. The signer writes it, so on its own it proves nothing.
    public var teamIdentifier: String?
    /// The code satisfies `anchor apple generic and certificate leaf[subject.OU] = "<teamIdentifier>"`:
    /// Apple issued the signing certificate (Developer ID, Mac App Store or development) to that team.
    /// `false` when ``teamIdentifier`` is absent or not a well-formed team identifier.
    public var satisfiesTeamAnchor: Bool
    /// `CFBundleIdentifier` from the Info.plist bound into the signature.
    public var sealedBundleIdentifier: String?
    /// `CFBundleIdentifier` of the bundle on disk at the code's path; not covered by any signature.
    public var bundleIdentifierAtPath: String?

    public init(
        validity: Validity, isAdHoc: Bool = false, satisfiesAppleAnchor: Bool = false, teamIdentifier: String? = nil,
        satisfiesTeamAnchor: Bool = false, sealedBundleIdentifier: String? = nil, bundleIdentifierAtPath: String? = nil
    ) {
        self.validity = validity
        self.isAdHoc = isAdHoc
        self.satisfiesAppleAnchor = satisfiesAppleAnchor
        self.teamIdentifier = teamIdentifier
        self.satisfiesTeamAnchor = satisfiesTeamAnchor
        self.sealedBundleIdentifier = sealedBundleIdentifier
        self.bundleIdentifierAtPath = bundleIdentifierAtPath
    }
}
