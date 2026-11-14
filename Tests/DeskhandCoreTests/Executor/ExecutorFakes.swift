import DeskhandCore
import DeskhandTestSupport
import Synchronization
import Testing

enum ExecutorFixture {
    static let t0 = ClockReading(wall: Timestamp(millisecondsSinceEpoch: 1_794_668_539_730), monotonic: .now)
    static let principal = Principal(certificateSubject: "CN=crew-executor,O=crew")
    static let otherPrincipal = Principal(certificateSubject: "CN=other-executor,O=crew")
    static let holder = HolderID("crew:alpha")!
    static let node = NodeAddress("10.0.0.21")!
    static let digestKey = DigestKey(bytes: Array(repeating: 7, count: DigestKey.byteCount))!
    static let frameSHA256 = SHA256Hex(hashing: Array("frame image".utf8))

    static func app(_ bundleID: String, _ name: String, signer: CodeSigner = .apple, certain: Bool = true)
        -> ObservedApp
    {
        ObservedApp(identity: AppIdentity(bundleID: BundleID(bundleID), signer: signer), name: name, isCertain: certain)
    }

    static let textEdit = app("com.apple.TextEdit", "TextEdit")
    static let notes = app("com.apple.Notes", "Notes")
    /// On the default deny list.
    static let terminal = app("com.apple.Terminal", "Terminal")
    /// Signed, but on no allowlist.
    static let unlisted = app("com.example.Unlisted", "Unlisted", signer: .team(TeamID("ABCDE12345")!))

    static let policy = AppPolicy(
        deskhandBundleID: BundleID("com.birbhomes.deskhand")!,
        allowed: [
            AllowedApp(bundleID: BundleID("com.apple.TextEdit")!, signer: .apple),
            AllowedApp(bundleID: BundleID("com.apple.Notes")!, signer: .apple),
        ])

    static let okReport = StateReducer.reduce(
        previous: .startup, signals: StateFixture.signals(), command: .arm(for: .seconds(3600)), now: t0
    ).report

    /// A report in which exactly `states` hold, reduced from `ok` at `reading`.
    static func report(_ states: Set<BlockingState>, conditions: Set<Condition> = [], at reading: ClockReading)
        -> StateReport
    {
        let command: ArmingCommand? =
            states.contains(.paused) ? .killSwitch : states.contains(.disarmed) ? .disarm : nil
        return StateReducer.reduce(
            previous: okReport, signals: StateFixture.signals(holding: states, conditions: conditions),
            command: command, now: reading
        ).report
    }

    static func acquired(
        ttlMs: Int = 30_000, by principal: Principal = principal, holder: HolderID = holder,
        at reading: ClockReading = t0
    ) -> LeaseManager {
        var manager = LeaseManager()
        _ = manager.apply(
            LeaseArguments(holderID: holder, command: .acquire(ttlMs: ttlMs)), principal: principal, state: .ok,
            now: reading)
        return manager
    }

    static let modifierCodes: [Modifier: PostedKeyCode] = [
        .control: PostedKeyCode(0x3B), .option: PostedKeyCode(0x3A), .shift: PostedKeyCode(0x38),
        .command: PostedKeyCode(0x37),
    ]
    static let carrier = PostedKeyCode(0x31)

    static func code(_ key: Key) -> PostedKeyCode { PostedKeyCode(UInt16(0x100 + Key.allCases.firstIndex(of: key)!)) }
}

enum MacTrace: Hashable, Sendable, CustomStringConvertible {
    /// The ledger's contents after a write that reached its disk.
    case ledger([HeldInput])
    case posted(InputEvent)
    case released(HeldInput)

    var description: String {
        switch self {
        case .ledger(let entries): "ledger \(entries)"
        case .posted(let event): "posted \(event)"
        case .released(let input): "released \(input)"
        }
    }
}

/// A fake Mac behind every synchronous seam: the state owner, identity, the person, the poster, the
/// layout, the clock and the ledger's disk. `afterPost[n]` changes the world right after the n-th
/// posted event, so the check before the next one sees it.
final class FakeMac: StateSource, IdentityMeasurer, UserActivitySource, EventPoster, KeyCodeMapper, ExecutionTimer,
    ExecutorObserver
{
    typealias Change = @Sendable (inout World, ClockReading) -> Void

    struct World: Sendable {
        var offsetMs: Int64 = 0
        var report = ExecutorFixture.okReport
        var lease = ExecutorFixture.acquired()
        var policy = ExecutorFixture.policy
        var frontmost = ExecutorFixture.textEdit
        var focus = ObservedWindow(owner: ExecutorFixture.textEdit, title: "notes.txt")
        var windows: @Sendable (GlobalPoint) -> ObservedWindow = { _ in
            ObservedWindow(owner: ExecutorFixture.textEdit, title: "notes.txt")
        }
        var idleMs: Int? = 60_000
        var missingKeys: Set<Key> = []
        var ledgerBytes: [UInt8]?
        var failLedgerWrites = false
        var failPostAt: Int?
        var failReleases = false
        var afterPost: [Int: Change] = [:]
        var trace: [MacTrace] = []
        var executionChanges: [Bool] = []
        var logAppends: [Bool] = []
        var cleanupPending: [Bool] = []
        var sleeps: [Duration] = []
        /// Runs inside every sleep, while the executor waits with input held.
        var onSleep: (@Sendable () async -> Void)?
        var patchVerdict = PatchVerdict.unchanged
        /// How long a patch recapture takes on the fake clock.
        var captureMs: Int64 = 0
    }

    let world: Mutex<World>

    init(_ configure: (inout World) -> Void = { _ in }) {
        var world = World()
        configure(&world)
        self.world = Mutex(world)
    }

    func change(_ body: (inout World) -> Void) { world.withLock { body(&$0) } }

    func read<T: Sendable>(_ body: (World) -> T) -> T { world.withLock { body($0) } }

    var reading: ClockReading { read { ExecutorFixture.t0.advanced(byMilliseconds: $0.offsetMs) } }

    var posted: [InputEvent] {
        read {
            $0.trace.compactMap { entry in
                guard case .posted(let event) = entry else { return nil }
                return event
            }
        }
    }

    var released: [HeldInput] {
        read {
            $0.trace.compactMap { entry in
                guard case .released(let input) = entry else { return nil }
                return input
            }
        }
    }

    func advance(byMilliseconds milliseconds: Int64) { change { $0.offsetMs += milliseconds } }

    // StateSource
    func snapshot() -> DeskSnapshot {
        read {
            DeskSnapshot(
                reading: ExecutorFixture.t0.advanced(byMilliseconds: $0.offsetMs), report: $0.report, lease: $0.lease,
                policy: $0.policy)
        }
    }

    // IdentityMeasurer
    func frontmostApp() -> ObservedApp { read(\.frontmost) }
    func keyboardFocus() -> ObservedWindow { read(\.focus) }
    func windows(at points: [GlobalPoint]) -> [ObservedWindow] { read { world in points.map(world.windows) } }

    // UserActivitySource
    func idleMilliseconds() -> Int? { read(\.idleMs) }

    // EventPoster
    func post(_ event: InputEvent) throws {
        let change: Change? = try world.withLock { world in
            let index = world.trace.count { if case .posted = $0 { true } else { false } } + 1
            if world.failPostAt == index { throw FakeFault() }
            world.trace.append(.posted(event))
            return world.afterPost[index]
        }
        if let change {
            let now = reading
            self.change { change(&$0, now) }
        }
    }

    func postRelease(_ input: HeldInput) throws {
        try world.withLock { world in
            if world.failReleases { throw FakeFault() }
            world.trace.append(.released(input))
        }
    }

    // KeyCodeMapper
    func code(for key: Key) -> PostedKeyCode? {
        read { $0.missingKeys.contains(key) } ? nil : ExecutorFixture.code(key)
    }

    func code(for modifier: Modifier) -> PostedKeyCode { ExecutorFixture.modifierCodes[modifier]! }

    var textCarrier: PostedKeyCode { ExecutorFixture.carrier }

    // ExecutionTimer
    func sleep(for duration: Duration) async {
        let milliseconds = Int64((duration / .milliseconds(1)).rounded(.up))
        let onSleep = world.withLock { world in
            world.sleeps.append(duration)
            world.offsetMs += max(1, milliseconds)
            return world.onSleep
        }
        await onSleep?()
        await Task.yield()
    }

    // ExecutorObserver
    func executionDidChange(executing: Bool) { change { $0.executionChanges.append(executing) } }
    func didPostEvent(at instant: ContinuousClock.Instant) {}
    func actionLogDidAppend(succeeded: Bool) { change { $0.logAppends.append(succeeded) } }
    func cleanupPendingDidChange(_ pending: Bool) { change { $0.cleanupPending.append(pending) } }

    // The ledger's disk
    var ledgerStore: FakeLedgerStore { FakeLedgerStore(mac: self) }

    fileprivate func writeLedger(_ bytes: [UInt8]) throws {
        try world.withLock { world in
            if world.failLedgerWrites { throw FakeFault() }
            world.ledgerBytes = bytes
            world.trace.append(.ledger(Self.decodeLedger(bytes)))
        }
    }

    static func decodeLedger(_ bytes: [UInt8]) -> [HeldInput] {
        guard case .array(let items)? = (try? JSONValue(parsing: bytes))?["held"] else { return [] }
        return items.compactMap { item -> HeldInput? in
            switch (item["key"], item["modifier"], item["button"]) {
            case (.number(let code)?, _, _): .key(PostedKeyCode(UInt16(code)))
            case (_, .number(let code)?, _): .modifier(PostedKeyCode(UInt16(code)))
            case (_, _, .string(let button)?): MouseButton(rawValue: button).map(HeldInput.button)
            default: nil
            }
        }
    }

    /// What a restart would find in the ledger.
    var ledgerOnDisk: [HeldInput] { read { $0.ledgerBytes.map(Self.decodeLedger) ?? [] } }
}

struct FakeFault: Error {}

struct FakeLedgerStore: HeldInputStore {
    let mac: FakeMac

    func load() throws -> [UInt8]? { mac.read(\.ledgerBytes) }
    func replace(with bytes: [UInt8]) throws { try mac.writeLedger(bytes) }
}

/// One frame per scope on one display: 400 x 300 frame pixels over 400 x 300 points, so frame
/// pixel `(x, y)` maps to global point `(x + 0.5, y + 0.5)`.
final class FakeFrames: FrameSource {
    static let size = PixelSize(width: 400, height: 300)
    static let generation = DisplayConfigGeneration(3)
    static let scope = FrameScope(principal: ExecutorFixture.principal, holderID: ExecutorFixture.holder)
    static let otherScope = FrameScope(principal: ExecutorFixture.otherPrincipal, holderID: ExecutorFixture.holder)

    private let store: Mutex<FrameStore>
    let gate: Gate?
    let frameIDs: [FrameScope: FrameID]

    init(capturedAt: Timestamp = ExecutorFixture.t0.wall, gate: Gate? = nil) {
        var store = FrameStore()
        let rect = GlobalRect(x: 0, y: 0, width: Double(Self.size.width), height: Double(Self.size.height))
        let capture = FrameCapture(
            displayID: DisplayID(1), displayConfigGeneration: Self.generation,
            geometry: FrameGeometry(captureRect: rect, outputPixelSize: Self.size, displayBounds: rect)!,
            sourcePixelSize: Self.size, pointPixelScale: 1, downscale: 1, capturedAt: capturedAt, maxAgeMs: 600_000,
            frontmostApp: ExecutorFixture.textEdit.appRef,
            pixels: FramePixels(
                size: Self.size, rgb: Array(repeating: 90, count: Self.size.width * Self.size.height * 3))!)
        var generator = SeededGenerator(state: 11)
        var ids: [FrameScope: FrameID] = [:]
        for scope in [Self.scope, Self.otherScope] {
            ids[scope] =
                try! store.record(
                    capture, for: scope, leaseHolder: scope, startedIn: store.epoch, now: capturedAt, using: &generator
                ).id
        }
        frameIDs = ids
        self.store = Mutex(store)
        self.gate = gate
    }

    var frameID: FrameID { frameIDs[Self.scope]! }

    func check(_ id: FrameID, in scope: FrameScope, for use: FrameUse, now: Timestamp) async -> FrameCheck {
        await gate?.pass()
        return store.withLock { store in
            switch store.validate(id, in: scope, for: use, displayConfigGeneration: Self.generation, now: now) {
            case .valid(let live): .valid(CheckedFrame(live: live, sha256: ExecutorFixture.frameSHA256))
            case .stale(let reason):
                .stale(reason, sha256: store.lookup(id, in: scope) == nil ? nil : ExecutorFixture.frameSHA256)
            }
        }
    }
}

/// Answers every patch with the fake Mac's `patchVerdict`, taking its `captureMs` to do it.
struct FakePatches: TargetPatchVerifier {
    let mac: FakeMac

    func verify(_ frame: LiveFrame, patches: [TargetPatch]) async -> [PatchVerdict] {
        let (verdict, captureMs) = mac.read { ($0.patchVerdict, $0.captureMs) }
        mac.advance(byMilliseconds: captureMs)
        return patches.map { _ in verdict }
    }
}

/// Holds a call where it passes until the test opens it, and says when one arrived.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let arrivals: AsyncStream<Void>.Continuation
    nonisolated let arrived: AsyncStream<Void>

    init() { (arrived, arrivals) = AsyncStream.makeStream() }

    func pass() async {
        arrivals.yield()
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// Loads the operation store from a disk that outlives it. `failNextLoad` refuses one load;
/// `faultAt` makes one write boundary of the first store fail.
final class FakeStoreLoader: OperationStoreLoader, @unchecked Sendable {
    let disk = FakeDisk()
    private let lock = Mutex(())
    var configuration = OperationStore.Configuration()
    var faultAt: Int?
    var failNextLoad = false

    func load(now: Timestamp) throws(OperationStoreLoadError) -> OperationStore {
        try lock.withLock { _ throws(OperationStoreLoadError) in
            if failNextLoad {
                failNextLoad = false
                throw .unreadable(.io(operation: "injected read", errno: 5))
            }
            let storage = FaultyStorage(disk, fault: .fail, at: faultAt)
            faultAt = nil
            return try OperationStore(storage: storage, configuration: configuration, now: now)
        }
    }
}

/// A connection that is open for its first `openReads` reads, then closed.
final class FakeConnection: ConnectionLiveness {
    private let reads: Mutex<Int>
    let openReads: Int

    init(openReads: Int = .max) {
        self.openReads = openReads
        reads = Mutex(0)
    }

    var isOpen: Bool {
        reads.withLock { reads in
            reads += 1
            return reads <= openReads
        }
    }
}

/// One executor on one fake Mac, with an in-memory action log that can be made to fail.
struct Harness {
    let mac: FakeMac
    let frames: FakeFrames
    let log: FaultInjectingActionLog<InMemoryActionLog>
    let loader: FakeStoreLoader
    let executor: InputExecutor

    init(
        mac: FakeMac = FakeMac(), frames: FakeFrames? = nil, loader: FakeStoreLoader = FakeStoreLoader(),
        actionsPerMinute: Int = 60
    ) throws {
        self.mac = mac
        self.frames = frames ?? FakeFrames()
        self.loader = loader
        log = FaultInjectingActionLog(wrapping: InMemoryActionLog())
        let seams = InputExecutor.Seams(
            state: mac, frames: self.frames, patches: FakePatches(mac: mac), identity: mac,
            activity: mac, poster: mac, keyCodes: mac, log: log, timer: mac, observer: mac, operationStore: loader)
        let ledger = try HeldInputLedger(store: mac.ledgerStore)
        executor = InputExecutor(
            configuration: .init(actionsPerMinute: actionsPerMinute), seams: seams, ledger: ledger,
            now: mac.reading.wall)
    }

    var frameID: String { frames.frameID.rawValue }

    func arguments(
        _ action: JSONValue, operation: String, frame: String?, permitted: [String]?, principal: Principal
    ) -> JSONObject {
        let ownFrame = frames.frameIDs[FrameScope(principal: principal, holderID: ExecutorFixture.holder)]!
        var arguments: JSONObject = [
            "holder_id": .string(ExecutorFixture.holder.rawValue), "frame_id": .string(frame ?? ownFrame.rawValue),
            "operation_id": .string(operation), "action": action,
        ]
        arguments["permitted_apps"] = permitted.map { .array($0.map(JSONValue.string)) }
        return arguments
    }

    func pointer(
        _ action: JSONValue, operation: String = "op-1", frame: String? = nil, permitted: [String]? = nil,
        principal: Principal = ExecutorFixture.principal, connection: any ConnectionLiveness = FakeConnection()
    ) throws -> EffectCall {
        let arguments = arguments(
            action, operation: operation, frame: frame, permitted: permitted, principal: principal)
        return EffectCall(
            principal: principal, nodeAddress: ExecutorFixture.node,
            arguments: .pointer(try PointerArguments(arguments: arguments)),
            digest: try RequestDigest(tool: .pointer, arguments: arguments, key: ExecutorFixture.digestKey),
            connection: connection)
    }

    func keyboard(
        _ action: JSONValue, operation: String = "op-1", frame: String? = nil, permitted: [String]? = nil,
        principal: Principal = ExecutorFixture.principal, connection: any ConnectionLiveness = FakeConnection()
    ) throws -> EffectCall {
        let arguments = arguments(
            action, operation: operation, frame: frame, permitted: permitted, principal: principal)
        return EffectCall(
            principal: principal, nodeAddress: ExecutorFixture.node,
            arguments: .keyboard(try KeyboardArguments(arguments: arguments)),
            digest: try RequestDigest(tool: .keyboard, arguments: arguments, key: ExecutorFixture.digestKey),
            connection: connection)
    }

    var logEntries: [ActionLogEntry] { get async { await log.base.entries } }

    func status(_ operation: String = "op-1") async throws -> StatusOperation {
        try await executor.operationStatus(
            for: OperationKey(
                principal: ExecutorFixture.principal, holderID: ExecutorFixture.holder,
                operationID: OperationID(operation)!))
    }
}

extension EffectAnswer {
    var toolError: ToolError? {
        guard case .error(let error) = self else { return nil }
        return error
    }

    var result: EffectResult? {
        guard case .completed(let result) = self else { return nil }
        return result
    }

    var code: ToolErrorCode? { toolError?.code }

    /// `operation` of an error, whichever context carries it.
    var operation: OperationView? {
        switch toolError?.operation {
        case .existing(let view)?, .result(let view)?, .replayed(let view, _)?: view
        case nil: nil
        }
    }

    var details: JSONObject? { structuredContent?["details"]?.objectValue }
}

extension JSONValue {
    var intValue: Int? {
        guard case .number(let number) = self else { return nil }
        return Int(exactly: number)
    }
}

extension HeldInput {
    static func modifierKey(_ modifier: Modifier) -> HeldInput { .modifier(ExecutorFixture.modifierCodes[modifier]!) }
    static func named(_ key: Key) -> HeldInput { .key(ExecutorFixture.code(key)) }
}
