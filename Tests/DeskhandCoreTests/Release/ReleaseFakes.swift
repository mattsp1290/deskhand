import DeskhandCore
import DeskhandTestSupport
import Synchronization
import Testing

/// Faults on the release path, shared by the poster and the ledger's disk. Attempts are counted
/// from 1 since the last ``arm(_:)``. A crash makes every later post and write fail without effect,
/// as nothing more happens in a dead process, until ``restart()``.
final class ReleaseFaults: Sendable {
    struct Plan: Sendable {
        /// Release posts that throw, by attempt.
        var failingReleases: Set<Int> = []
        /// Ledger writes that throw without reaching the disk, by attempt.
        var failingWrites: Set<Int> = []
        /// The write attempt during which the process dies: its bytes never reach the disk.
        var crashAtWrite: Int?
        var releaseAttempts = 0
        var writeAttempts = 0
        var crashed = false
    }

    private let plan = Mutex(Plan())

    func arm(_ body: (inout Plan) -> Void) {
        plan.withLock { plan in
            plan.releaseAttempts = 0
            plan.writeAttempts = 0
            body(&plan)
        }
    }

    /// A new process on the same Mac: the disk and what the Mac holds down survive.
    func restart() { plan.withLock { $0 = Plan() } }

    var crashed: Bool { plan.withLock(\.crashed) }

    fileprivate func checkPost() throws {
        if plan.withLock(\.crashed) { throw ReleaseFault.dead }
    }

    fileprivate func checkRelease() throws {
        try plan.withLock { plan in
            if plan.crashed { throw ReleaseFault.dead }
            plan.releaseAttempts += 1
            if plan.failingReleases.contains(plan.releaseAttempts) { throw ReleaseFault.injected }
        }
    }

    fileprivate func checkWrite() throws {
        try plan.withLock { plan in
            if plan.crashed { throw ReleaseFault.dead }
            plan.writeAttempts += 1
            if plan.crashAtWrite == plan.writeAttempts {
                plan.crashed = true
                throw ReleaseFault.dead
            }
            if plan.failingWrites.contains(plan.writeAttempts) { throw ReleaseFault.injected }
        }
    }
}

enum ReleaseFault: Error {
    case injected
    /// The process has died.
    case dead
}

/// The fake Mac's poster behind ``ReleaseFaults``.
struct FaultyPoster: EventPoster {
    let mac: FakeMac
    let faults: ReleaseFaults

    func post(_ event: InputEvent) throws {
        try faults.checkPost()
        try mac.post(event)
    }

    func postRelease(_ input: HeldInput) throws {
        try faults.checkRelease()
        try mac.postRelease(input)
    }
}

/// The fake Mac's ledger disk behind ``ReleaseFaults``.
struct FaultyLedgerStore: HeldInputStore {
    let mac: FakeMac
    let faults: ReleaseFaults

    func load() throws -> [UInt8]? { try mac.ledgerStore.load() }

    func replace(with bytes: [UInt8]) throws {
        try faults.checkWrite()
        try mac.ledgerStore.replace(with: bytes)
    }
}

extension FakeMac {
    /// What the Mac holds down now because of deskhand: every down event posted and not yet let up.
    /// A key-up for something not down changes nothing.
    var heldDown: Set<HeldInput> {
        var held: Set<HeldInput> = []
        for entry in read(\.trace) {
            switch entry {
            case .posted(let event):
                if let input = event.press { held.insert(input) }
                if let input = event.release { held.remove(input) }
            case .released(let input): held.remove(input)
            case .ledger: break
            }
        }
        return held
    }

    /// Puts `entries` in the ledger file, as a previous run would have left them.
    func leaveInLedger(_ entries: [HeldInput]) throws {
        var ledger = try HeldInputLedger(store: ledgerStore)
        for input in entries { try ledger.willPress(input) }
    }

    func setState(_ states: Set<BlockingState>, conditions: Set<Condition> = []) {
        let report =
            states.isEmpty && conditions.isEmpty
            ? ExecutorFixture.okReport : ExecutorFixture.report(states, conditions: conditions, at: reading)
        change { $0.report = report }
    }
}

/// One executor on one fake Mac whose release path and ledger disk can fail or crash, with the
/// default release handler unless a test passes another.
struct ReleaseHarness {
    let mac: FakeMac
    let faults: ReleaseFaults
    let frames: FakeFrames
    let loader: FakeStoreLoader
    let executor: InputExecutor

    init(
        mac: FakeMac = FakeMac(), faults: ReleaseFaults = ReleaseFaults(), frames: FakeFrames = FakeFrames(),
        loader: FakeStoreLoader = FakeStoreLoader(), releases: (any ReleaseHandler)? = nil
    ) throws {
        self.mac = mac
        self.faults = faults
        self.frames = frames
        self.loader = loader
        var seams = InputExecutor.Seams(
            state: mac, frames: frames, patches: FakePatches(mac: mac), identity: mac, activity: mac,
            poster: FaultyPoster(mac: mac, faults: faults), keyCodes: mac, log: InMemoryActionLog(), timer: mac,
            waitTimer: ManualWaitLimits(), observer: mac, operationStore: loader)
        if let releases { seams.releases = releases }
        let ledger = try HeldInputLedger(store: FaultyLedgerStore(mac: mac, faults: faults))
        executor = InputExecutor(seams: seams, ledger: ledger, now: mac.reading.wall)
    }

    /// The next run of deskhand on the same Mac after the process died: the disks and what the Mac
    /// holds down survive, and a new executor reads the ledger the dead one left.
    func restarted() throws -> ReleaseHarness {
        faults.restart()
        return try ReleaseHarness(mac: mac, faults: faults, frames: frames, loader: loader)
    }

    func keyboard(_ action: JSONValue, operation: String = "op-1") throws -> EffectCall {
        let arguments = arguments(action, operation: operation)
        return EffectCall(
            principal: ExecutorFixture.principal, nodeAddress: ExecutorFixture.node,
            arguments: .keyboard(try KeyboardArguments(arguments: arguments)),
            digest: try RequestDigest(tool: .keyboard, arguments: arguments, key: ExecutorFixture.digestKey),
            connection: FakeConnection())
    }

    func pointer(_ action: JSONValue, operation: String = "op-1") throws -> EffectCall {
        let arguments = arguments(action, operation: operation)
        return EffectCall(
            principal: ExecutorFixture.principal, nodeAddress: ExecutorFixture.node,
            arguments: .pointer(try PointerArguments(arguments: arguments)),
            digest: try RequestDigest(tool: .pointer, arguments: arguments, key: ExecutorFixture.digestKey),
            connection: FakeConnection())
    }

    /// A `move`, which presses nothing: admitted only when no state, condition or fault refuses it.
    func move(_ operation: String) async throws -> EffectAnswer {
        await executor.perform(try pointer(["type": "move", "x": 1, "y": 1], operation: operation))
    }

    private func arguments(_ action: JSONValue, operation: String) -> JSONObject {
        [
            "holder_id": .string(ExecutorFixture.holder.rawValue), "frame_id": .string(frames.frameID.rawValue),
            "operation_id": .string(operation), "action": action,
        ]
    }
}

/// A `keyboard` `press` of `control+option+shift+k`, held long enough for an abort to land while all
/// four are down.
enum HeldChord {
    static let action: JSONValue = [
        "type": "press", "key": "k", "modifiers": ["shift", "control", "option"], "hold_ms": 500,
    ]
    /// The order the executor presses them in, which is the ledger's order.
    static let pressed: [HeldInput] = [
        .modifierKey(.control), .modifierKey(.option), .modifierKey(.shift), .named(.k),
    ]
    static var released: [HeldInput] { pressed.reversed() }
    /// The chord's down events: an abort set off after the last of them finds all four down.
    static let downEvents = 4

    /// A fake Mac on which the states and conditions given change right after the last down event.
    static func mac(abortingWith states: Set<BlockingState>, conditions: Set<Condition> = []) -> FakeMac {
        FakeMac {
            $0.afterPost[downEvents] = { world, now in
                world.report = ExecutorFixture.report(states, conditions: conditions, at: now)
            }
        }
    }
}
