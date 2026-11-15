/// What one platform signal said about the fact it reports.
public enum SignalReading: CaseIterable, Hashable, Sendable {
    case present
    case absent
    /// The signal could not be read, or its answer is uncertain.
    case uncertain

    /// Fail closed (contract 10.1): only a certain `absent` lets the fact count as absent.
    public var holds: Bool { self != .absent }
}

/// A platform signal behind a blocking state (contract 10.1). Each case names the fact that blocks,
/// so `present` always means "this blocks". Which macOS API reads it is the spike's choice.
public enum PlatformSignal: CaseIterable, Hashable, Sendable {
    /// deskhand's login session does not own the console.
    case notConsole
    /// The console shows the login window.
    case loginWindow
    case locked
    /// Any active display is asleep.
    case displayAsleep
    case permissionMissing
    case permissionStale
    case secureInput

    /// The state the signal makes hold. The login window has no state of its own and always means
    /// `not_console`, even when the console-ownership signal disagrees (contract 11.4).
    public var feeds: BlockingState {
        switch self {
        case .notConsole, .loginWindow: .notConsole
        case .locked: .locked
        case .displayAsleep: .displayAsleep
        case .permissionMissing: .permissionMissing
        case .permissionStale: .permissionStale
        case .secureInput: .secureInput
        }
    }
}

/// What deskhand itself was doing with input when a reduction ran, for the rule that only a person
/// arms (contract 10.4).
public struct OwnInputActivity: Hashable, Sendable {
    /// The arming command of this reduction came from an input event that deskhand posted itself.
    public var commandFromPostedEvent: Bool
    public var operationExecuting: Bool
    /// When deskhand last posted an event, on the monotonic clock.
    public var lastPostedEvent: ContinuousClock.Instant?

    public init(commandFromPostedEvent: Bool, operationExecuting: Bool, lastPostedEvent: ContinuousClock.Instant?) {
        self.commandFromPostedEvent = commandFromPostedEvent
        self.operationExecuting = operationExecuting
        self.lastPostedEvent = lastPostedEvent
    }

    /// Nothing posted, nothing executing.
    public static let idle = OwnInputActivity(
        commandFromPostedEvent: false, operationExecuting: false, lastPostedEvent: nil)
}

/// Everything the reducer reads at one instant, apart from arming and the clock.
public struct StateSignals: Hashable, Sendable {
    /// The LAN-gate allowance (contract 14.3). Anything but ``AllowanceVerdict/valid(expiresAt:)``
    /// means `gated`, and so does a valid one once its `expires_at` has passed: the report keeps the
    /// expiry and compares it with the clock on every read.
    public var allowance: AllowanceVerdict
    /// A signal with no entry reads as `uncertain`.
    public var readings: [PlatformSignal: SignalReading]
    public var credentialsWarning: Bool
    public var cleanupPending: Bool
    public var logUnavailable: Bool
    public var ownInput: OwnInputActivity

    public init(
        allowance: AllowanceVerdict, readings: [PlatformSignal: SignalReading], credentialsWarning: Bool,
        cleanupPending: Bool, logUnavailable: Bool, ownInput: OwnInputActivity
    ) {
        self.allowance = allowance
        self.readings = readings
        self.credentialsWarning = credentialsWarning
        self.cleanupPending = cleanupPending
        self.logUnavailable = logUnavailable
        self.ownInput = ownInput
    }

    public subscript(signal: PlatformSignal) -> SignalReading { readings[signal] ?? .uncertain }

    static let unread = StateSignals(
        allowance: .missing, readings: [:], credentialsWarning: false, cleanupPending: false, logUnavailable: false,
        ownInput: .idle)
}

extension AllowanceVerdict {
    func isValid(at now: Timestamp) -> Bool {
        if case .valid(let expiresAt) = self { return now < expiresAt }
        return false
    }
}
