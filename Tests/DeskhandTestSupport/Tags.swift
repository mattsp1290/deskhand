import Foundation
import Testing

extension Tag {
    /// Needs a TCC grant, a logged-in GUI session or a real display. CI never runs these.
    /// Always pair with `.macSessionTestsEnabled`; the tag alone does not skip anything.
    /// `scripts/check-mac-session-gate.sh` enforces the pairing in CI.
    @Tag public static var requiresMacSession: Self
}

/// Opt-in switch for `requiresMacSession` tests, set only by the manual on-Mac checklist.
public let macSessionTestsEnvironmentKey = "DESKHAND_MAC_SESSION_TESTS"

/// Whether `environment` opts in to Mac-session tests. Only the exact value "1" does, so an
/// unset or mistyped variable keeps them skipped.
public func macSessionTestsAreEnabled(in environment: [String: String]) -> Bool {
    environment[macSessionTestsEnvironmentKey] == "1"
}

extension Trait where Self == ConditionTrait {
    /// Swift Testing 6.2 cannot filter by tag on the `swift test` command line, so the
    /// exclusion is an opt-in condition: unset (CI, plain `swift test`) means skipped.
    public static var macSessionTestsEnabled: Self {
        .enabled(
            if: macSessionTestsAreEnabled(in: ProcessInfo.processInfo.environment),
            "requires a TCC grant, GUI session or real display; set \(macSessionTestsEnvironmentKey)=1"
        )
    }
}
