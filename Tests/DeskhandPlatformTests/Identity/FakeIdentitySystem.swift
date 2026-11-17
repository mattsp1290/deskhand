import DeskhandCore
import DeskhandPlatform
import Foundation
import Synchronization

final class FakeIdentitySystem: IdentitySystem {
    let windows: [IdentityWindowEntry]?
    let frontmost: pid_t?
    let focus: FocusedApplicationLookup
    let signatures: [pid_t: CodeSignatureLookup]
    let names: [pid_t: String]
    let focusedTitles: [pid_t: String]
    let activation: [pid_t: ActivationLookup]
    let reused: Set<pid_t>
    let reusedBeforeFirstRead: Set<pid_t>
    let deactivatedAfterFirstRead: Set<pid_t>
    /// The pid is reused once its start time has been read this many times.
    let reusedAfterReads: [pid_t: Int]
    private let lookups = Mutex<[pid_t: Int]>([:])
    private let startTimeReads = Mutex<[pid_t: Int]>([:])
    private let activationReads = Mutex<[pid_t: Int]>([:])

    init(
        windows: [IdentityWindowEntry]? = [], frontmost: pid_t? = nil,
        focus: FocusedApplicationLookup = .noFocus, signatures: [pid_t: CodeSignatureLookup] = [:],
        activation: [pid_t: ActivationLookup] = [:], names: [pid_t: String] = [:],
        focusedTitles: [pid_t: String] = [:], reused: Set<pid_t> = [], reusedBeforeFirstRead: Set<pid_t> = [],
        deactivatedAfterFirstRead: Set<pid_t> = [], reusedAfterReads: [pid_t: Int] = [:]
    ) {
        self.windows = windows
        self.frontmost = frontmost
        self.focus = focus
        self.signatures = signatures
        self.names = names
        self.focusedTitles = focusedTitles
        self.activation = activation
        self.reused = reused
        self.reusedBeforeFirstRead = reusedBeforeFirstRead
        self.deactivatedAfterFirstRead = deactivatedAfterFirstRead
        self.reusedAfterReads = reusedAfterReads
    }

    static let now = ProcessStartTime(seconds: 1_000_000, microseconds: 0)

    func signatureLookups(of pid: pid_t) -> Int { lookups.withLock { $0[pid, default: 0] } }

    func wallClock() -> ProcessStartTime { Self.now }
    func activation(of pid: pid_t) -> ActivationLookup {
        let earlierReads = activationReads.withLock { reads in
            defer { reads[pid, default: 0] += 1 }
            return reads[pid, default: 0]
        }
        if deactivatedAfterFirstRead.contains(pid), earlierReads > 0 { return .inactive }
        return activation[pid] ?? .inactive
    }
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
        if reusedBeforeFirstRead.contains(pid) {
            return ProcessStartTime(seconds: Self.now.seconds + 1, microseconds: 0)
        }
        let earlierReads = startTimeReads.withLock { reads in
            defer { reads[pid, default: 0] += 1 }
            return reads[pid, default: 0]
        }
        let replaced =
            (reused.contains(pid) && earlierReads > 0) || reusedAfterReads[pid].map { earlierReads >= $0 } == true
        return ProcessStartTime(seconds: 1_000 + Int64(pid), microseconds: replaced ? 1 : 0)
    }
}

enum IdentityFixtures {
    static let team = TeamID("ABCDE12345")!

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
