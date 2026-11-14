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

/// Everything the reducer reads at one instant, apart from arming and the clock.
public struct StateSignals: Hashable, Sendable {
    /// The LAN-gate allowance is present and valid now (contract 14.3). `false` means `gated`.
    public var allowanceValid: Bool
    /// A signal with no entry reads as `uncertain`.
    public var readings: [PlatformSignal: SignalReading]
    public var credentialsWarning: Bool
    public var cleanupPending: Bool
    public var logUnavailable: Bool

    public init(
        allowanceValid: Bool, readings: [PlatformSignal: SignalReading], credentialsWarning: Bool,
        cleanupPending: Bool, logUnavailable: Bool
    ) {
        self.allowanceValid = allowanceValid
        self.readings = readings
        self.credentialsWarning = credentialsWarning
        self.cleanupPending = cleanupPending
        self.logUnavailable = logUnavailable
    }

    public subscript(signal: PlatformSignal) -> SignalReading { readings[signal] ?? .uncertain }

    /// Nothing read yet: no valid allowance, and every platform signal uncertain.
    static let unread = StateSignals(
        allowanceValid: false, readings: [:], credentialsWarning: false, cleanupPending: false,
        logUnavailable: false)
}
