import DeskhandCore
import DeskhandTestSupport
import Foundation
import Synchronization

/// One Mac across runs of deskhand: the operation records and the held-input ledger are real
/// owner-only files in a temporary directory, and the fake Mac stands behind every platform seam.
/// Each ``start(firstReading:records:ledgerStore:poster:)`` is one run, as after a crash or a stop.
struct RecoveryRig {
    let directory: String
    let mac = FakeMac()
    let frames = FakeFrames()

    var journalPath: String { directory + "/operations.journal" }
    var ledgerPath: String { directory + "/held-input.ledger" }

    static func with(_ body: (RecoveryRig) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskhand-recovery-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try await body(RecoveryRig(directory: directory))
    }

    /// One start. The state owner seeds itself from the world, then reduces its first reading of
    /// the Mac, under which exactly `firstReading` holds besides `disarmed`; `nil` when it has read
    /// nothing yet.
    func start(
        firstReading: Set<BlockingState>? = [], records: (any OperationStoreLoader)? = nil,
        ledgerStore: (any HeldInputStore & Sendable)? = nil, poster: (any EventPoster)? = nil
    ) async -> RecoveredStart {
        let recovery = Recovery(ledgerStore: ledgerStore ?? FileHeldInputStore(path: ledgerPath))
        let (mac, frames, now) = (mac, frames, mac.reading)
        return await recovery.start(at: now) { world in
            var report = world.report
            if let firstReading {
                report =
                    StateReducer.reduce(
                        previous: report, signals: StateFixture.signals(holding: firstReading), now: now
                    ).report
            }
            mac.change {
                $0.report = report
                $0.lease = world.lease
            }
            return InputExecutor.Seams(
                state: mac, frames: frames, patches: FakePatches(mac: mac), identity: mac, activity: mac,
                poster: poster ?? mac, keyCodes: mac, log: InMemoryActionLog(), timer: mac,
                waitTimer: ManualWaitLimits(), observer: mac,
                operationStore: records ?? FileOperationStoreLoader(path: journalPath))
        }
    }

    /// Records as a run that died left them: `accepted` is admitted only, `executing` posted
    /// `eventsPosted` events, `completed` ran to its end.
    func leaveRecords(
        accepted: [OperationKey] = [], executing: [OperationKey: Int] = [:], completed: [OperationKey] = []
    ) throws {
        let store = try OperationStore(storage: FileOperationStorage(path: journalPath), now: mac.reading.wall)
        for key in accepted { _ = try Sample.admit(store, key, at: mac.reading.wall) }
        for (key, count) in executing {
            let ticket = try Sample.admit(store, key, at: mac.reading.wall)
            try store.markExecuting(ticket)
            try store.recordProgress(ticket, eventsPosted: count)
        }
        for key in completed {
            let ticket = try Sample.admit(store, key, at: mac.reading.wall)
            try store.markExecuting(ticket)
            _ = try store.finish(ticket, Sample.completed(), eventsPosted: 2)
        }
    }

    /// Puts `entries` in the ledger file, in press order, as a previous run would have left them.
    func leaveInLedger(_ entries: [HeldInput]) throws {
        var ledger = try HeldInputLedger(store: FileHeldInputStore(path: ledgerPath))
        for input in entries { try ledger.willPress(input) }
    }

    /// What the next run would find in the ledger.
    func ledgerOnDisk() throws -> [HeldInput] {
        try HeldInputLedger(store: FileHeldInputStore(path: ledgerPath)).pending()
    }

    func bytes(at path: String) throws -> [UInt8]? { try DurableFile(path: path).read() }

    /// The journal's lines, sorted: a rewrite puts records admitted in the same millisecond in no
    /// fixed order.
    func journalLines() throws -> [String] {
        String(decoding: try bytes(at: journalPath) ?? [], as: UTF8.self).split(separator: "\n").map(String.init)
            .sorted()
    }

    /// A person armed deskhand, the Mac is `ok` and the caller acquired the lease.
    func makeReady() {
        let now = mac.reading
        mac.change {
            $0.report = ExecutorFixture.okReport
            $0.lease = ExecutorFixture.acquired(at: now)
        }
    }

    /// A `move`, which presses nothing: admitted only when nothing refuses it.
    func move(on executor: InputExecutor, operation: String) async throws -> EffectAnswer {
        let arguments: JSONObject = [
            "holder_id": .string(ExecutorFixture.holder.rawValue), "frame_id": .string(frames.frameID.rawValue),
            "operation_id": .string(operation), "action": ["type": "move", "x": 1, "y": 1],
        ]
        let call = EffectCall(
            principal: ExecutorFixture.principal, nodeAddress: ExecutorFixture.node,
            arguments: .pointer(try PointerArguments(arguments: arguments)),
            digest: try RequestDigest(tool: .pointer, arguments: arguments, key: ExecutorFixture.digestKey),
            connection: FakeConnection())
        return await executor.perform(call)
    }
}

/// The fake Mac's poster in a process that dies at its `diesAt`-th release: that release and every
/// later one never reach the Mac.
final class DyingPoster: EventPoster {
    private let mac: FakeMac
    private let diesAt: Int
    private let attempts = Mutex(0)

    init(_ mac: FakeMac, diesAt: Int) {
        self.mac = mac
        self.diesAt = diesAt
    }

    func post(_ event: InputEvent) throws { try mac.post(event) }

    func postRelease(_ input: HeldInput) throws {
        let attempt = attempts.withLock { attempts in
            attempts += 1
            return attempts
        }
        guard attempt < diesAt else { throw FakeFault() }
        try mac.postRelease(input)
    }
}
