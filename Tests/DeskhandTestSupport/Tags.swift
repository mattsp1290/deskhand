import Foundation
import Testing

extension Tag {
    /// Needs a TCC grant, a logged-in GUI session or a real display. CI never runs these.
    /// Always pair with `.macSessionTestsEnabled`; the tag alone does not skip anything.
    @Tag public static var requiresMacSession: Self
}

/// Opt-in switch for `requiresMacSession` tests, set only by the manual on-Mac checklist.
public let macSessionTestsEnvironmentKey = "DESKHAND_MAC_SESSION_TESTS"

extension Trait where Self == ConditionTrait {
    /// Swift Testing 6.2 cannot filter by tag on the `swift test` command line, so the
    /// exclusion is an opt-in condition: unset (CI, plain `swift test`) means skipped.
    public static var macSessionTestsEnabled: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment[macSessionTestsEnvironmentKey] == "1",
            "requires a TCC grant, GUI session or real display; set \(macSessionTestsEnvironmentKey)=1"
        )
    }
}
