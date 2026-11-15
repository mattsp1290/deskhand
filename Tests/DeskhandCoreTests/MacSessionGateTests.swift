import DeskhandTestSupport
import Foundation
import Testing

/// These run everywhere, CI included, so a gate that stops skipping fails here first.
/// Pairing the tag with the trait is checked by `scripts/check-mac-session-gate.sh`.
@Suite(.timeLimit(.minutes(1))) struct MacSessionGateTests {
    @Test(arguments: [
        ([String: String](), false),
        ([macSessionTestsEnvironmentKey: "1"], true),
        ([macSessionTestsEnvironmentKey: "0"], false),
        ([macSessionTestsEnvironmentKey: ""], false),
        ([macSessionTestsEnvironmentKey: "true"], false),
        ([macSessionTestsEnvironmentKey: " 1"], false),
        (["OTHER_VARIABLE": "1"], false),
    ])
    func optInNeedsExactlyOne(environment: [String: String], enabled: Bool) {
        #expect(macSessionTestsAreEnabled(in: environment) == enabled)
    }

    @Test func traitFollowsTheProcessEnvironment() async throws {
        let expected = macSessionTestsAreEnabled(in: ProcessInfo.processInfo.environment)
        #expect(try await ConditionTrait.macSessionTestsEnabled.evaluate() == expected)
    }
}
