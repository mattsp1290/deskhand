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
    /// Successive answers to `activation(of:)`, the last repeating. A pid without answers is inactive.
    let activations: [pid_t: [ActivationLookup]]
    /// Successive answers to `processStartTime(of:)`, the last repeating. A pid without answers started
    /// at ``started(_:)`` while it has a signature, and is not running otherwise.
    let startTimes: [pid_t: [ProcessStartTime?]]
    /// After this many reads of a pid, start time and activation alike and in the order the probe made
    /// them, a new process that started at ``replaced(_:)`` and is active answers for it. Unlike the
    /// scripts above, this ties reuse to where it falls between the two kinds of read.
    let reusedAfterReads: [pid_t: Int]
    private let lookups = Mutex<[pid_t: Int]>([:])
    private let reads = Mutex<[Read]>([])

    enum Read: Hashable {
        case activation(pid_t)
        case startTime(pid_t)

        var pid: pid_t {
            switch self {
            case .activation(let pid), .startTime(let pid): pid
            }
        }
    }

    /// Every activation and start-time read, in order. Script positions count from the first read of
    /// this fake, across probe calls.
    var readLog: [Read] { reads.withLock { $0 } }

    /// `activation` is shorthand for a single answer per pid; `activations` takes precedence.
    init(
        windows: [IdentityWindowEntry]? = [], frontmost: pid_t? = nil,
        focus: FocusedApplicationLookup = .noFocus, signatures: [pid_t: CodeSignatureLookup] = [:],
        activation: [pid_t: ActivationLookup] = [:], activations: [pid_t: [ActivationLookup]] = [:],
        names: [pid_t: String] = [:], focusedTitles: [pid_t: String] = [:],
        startTimes: [pid_t: [ProcessStartTime?]] = [:], reusedAfterReads: [pid_t: Int] = [:]
    ) {
        self.windows = windows
        self.frontmost = frontmost
        self.focus = focus
        self.signatures = signatures
        self.names = names
        self.focusedTitles = focusedTitles
        self.activations = activation.mapValues { [$0] }.merging(activations) { $1 }
        self.startTimes = startTimes
        self.reusedAfterReads = reusedAfterReads
    }

    static let now = ProcessStartTime(seconds: 1_000_000, microseconds: 0)

    /// When the process first running as `pid` started.
    static func started(_ pid: pid_t) -> ProcessStartTime {
        ProcessStartTime(seconds: 1_000 + Int64(pid), microseconds: 0)
    }

    /// When a later process reusing `pid` started; still before ``now``.
    static func replaced(_ pid: pid_t) -> ProcessStartTime {
        ProcessStartTime(seconds: 1_000 + Int64(pid), microseconds: 1)
    }

    /// A start time after ``now``: the pid was reused after the probe's clock reading.
    static let startedAfterNow = ProcessStartTime(seconds: now.seconds + 1, microseconds: 0)

    func signatureLookups(of pid: pid_t) -> Int { lookups.withLock { $0[pid, default: 0] } }

    func wallClock() -> ProcessStartTime { Self.now }
    func activation(of pid: pid_t) -> ActivationLookup {
        let (earlier, reused) = record(.activation(pid))
        if reused { return .active }
        return activations[pid].map { answer($0, after: earlier) } ?? .inactive
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
        let (earlier, reused) = record(.startTime(pid))
        if reused { return Self.replaced(pid) }
        if let script = startTimes[pid] { return answer(script, after: earlier) }
        return signatures[pid] == nil ? nil : Self.started(pid)
    }

    /// Logs `read`; returns how many reads of the same kind came before it, and whether the pid has
    /// been reused by then.
    private func record(_ read: Read) -> (earlier: Int, reused: Bool) {
        reads.withLock { reads in
            let earlier = reads.count { $0 == read }
            let ofPid = reads.count { $0.pid == read.pid }
            reads.append(read)
            return (earlier, reusedAfterReads[read.pid].map { ofPid >= $0 } ?? false)
        }
    }

    private func answer<Answer>(_ script: [Answer], after earlier: Int) -> Answer {
        precondition(!script.isEmpty, "a scripted pid needs at least one answer")
        return script[min(earlier, script.count - 1)]
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
