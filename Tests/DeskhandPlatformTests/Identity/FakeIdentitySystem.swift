import DeskhandCore
import DeskhandPlatform
import Foundation
import Synchronization

/// An ``IdentitySystem`` that answers from fixed tables and counts signature lookups per process.
///
/// A process with a signature entry is running; any other pid has no process. A pid in `reused` is
/// taken over by a new process right after its start time is first read.
final class FakeIdentitySystem: IdentitySystem {
    let windows: [IdentityWindowEntry]?
    let frontmost: pid_t?
    let focus: FocusedApplicationLookup
    let signatures: [pid_t: CodeSignatureLookup]
    let names: [pid_t: String]
    let focusedTitles: [pid_t: String]
    let reused: Set<pid_t>
    private let lookups = Mutex<[pid_t: Int]>([:])
    private let startTimeReads = Mutex<[pid_t: Int]>([:])

    init(
        windows: [IdentityWindowEntry]? = [], frontmost: pid_t? = nil,
        focus: FocusedApplicationLookup = .noFocus, signatures: [pid_t: CodeSignatureLookup] = [:],
        names: [pid_t: String] = [:], focusedTitles: [pid_t: String] = [:], reused: Set<pid_t> = []
    ) {
        self.windows = windows
        self.frontmost = frontmost
        self.focus = focus
        self.signatures = signatures
        self.names = names
        self.focusedTitles = focusedTitles
        self.reused = reused
    }

    func signatureLookups(of pid: pid_t) -> Int { lookups.withLock { $0[pid, default: 0] } }

    func onScreenWindows() -> [IdentityWindowEntry]? { windows }
    func frontmostProcess() -> pid_t? { frontmost }
    func focusedApplication() -> FocusedApplicationLookup { focus }

    func codeSignature(of pid: pid_t) -> CodeSignatureLookup {
        lookups.withLock { $0[pid, default: 0] += 1 }
        return signatures[pid] ?? .processGone
    }

    func localizedName(of pid: pid_t) -> String? { names[pid] }
    func focusedWindowTitle(of pid: pid_t) -> String? { focusedTitles[pid] }

    func processStartTime(of pid: pid_t) -> ProcessStartTime? {
        guard signatures[pid] != nil else { return nil }
        let earlierReads = startTimeReads.withLock { reads in
            defer { reads[pid, default: 0] += 1 }
            return reads[pid, default: 0]
        }
        let replaced = reused.contains(pid) && earlierReads > 0
        return ProcessStartTime(seconds: 1_000 + Int64(pid), microseconds: replaced ? 1 : 0)
    }
}

enum IdentityFixtures {
    static let team = TeamID("ABCDE12345")!

    /// Signed with an Apple-issued certificate for `team`.
    static func teamSigned(_ bundleID: String, team: String = "ABCDE12345") -> CodeSignatureLookup {
        .found(
            CodeSignatureFacts(
                validity: .valid, teamIdentifier: team, satisfiesTeamAnchor: true, sealedBundleIdentifier: bundleID))
    }

    static func appleSigned(_ bundleID: String) -> CodeSignatureLookup {
        .found(CodeSignatureFacts(validity: .valid, satisfiesAppleAnchor: true, sealedBundleIdentifier: bundleID))
    }

    static func window(
        pid: pid_t?, layer: Int? = 0, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
        title: String? = nil, owner: String? = nil
    ) -> IdentityWindowEntry {
        IdentityWindowEntry(
            ownerPID: pid, ownerName: owner, layer: layer, bounds: GlobalRect(x: x, y: y, width: width, height: height),
            title: title)
    }
}
