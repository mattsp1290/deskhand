import DeskhandTestSupport
import Foundation
import Testing

@Suite struct MacSessionGateTests {
    /// Fails if the gate ever lets a `requiresMacSession` test run without the opt-in.
    @Test(.tags(.requiresMacSession), .macSessionTestsEnabled)
    func runsOnlyWhenOptedIn() {
        #expect(ProcessInfo.processInfo.environment[macSessionTestsEnvironmentKey] == "1")
    }
}
