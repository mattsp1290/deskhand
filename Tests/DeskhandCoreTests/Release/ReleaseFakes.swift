import DeskhandCore
import DeskhandTestSupport
import Synchronization
import Testing

final class ReleaseFaults: Sendable {
    struct Plan: Sendable {
        var failingReleases: Set<Int> = []
        var failingWrites: Set<Int> = []
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
    case dead
}

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

enum HeldChord {
    static let action: JSONValue = [
        "type": "press", "key": "k", "modifiers": ["shift", "control", "option"], "hold_ms": 500,
    ]
    static let pressed: [HeldInput] = [
        .modifierKey(.control), .modifierKey(.option), .modifierKey(.shift), .named(.k),
    ]
    static var released: [HeldInput] { pressed.reversed() }
    static let downEvents = 4

    static func mac(abortingWith states: Set<BlockingState>, conditions: Set<Condition> = []) -> FakeMac {
        FakeMac {
            $0.afterPost[downEvents] = { world, now in
                world.report = ExecutorFixture.report(states, conditions: conditions, at: now)
            }
        }
    }
}
