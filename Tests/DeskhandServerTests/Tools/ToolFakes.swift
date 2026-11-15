import DeskhandCore
import DeskhandTestSupport
import Foundation
import Synchronization

@testable import DeskhandServer

enum ToolFixture {
    static let t0 = ClockReading(wall: Timestamp(millisecondsSinceEpoch: 1_794_668_539_730), monotonic: .now)
    static let principal = Principal(certificateSubject: "CN=crew-executor,O=crew")
    static let otherPrincipal = Principal(certificateSubject: "CN=other-executor,O=crew")
    static let holder = HolderID("crew:alpha")!
    static let otherHolder = HolderID("crew:beta")!
    static let node = NodeAddress("10.0.0.21")!
    static let caller = ToolCaller(principal: principal, nodeAddress: node)
    static let otherCaller = ToolCaller(principal: otherPrincipal, nodeAddress: node)
    static let digestKey = DigestKey(bytes: Array(repeating: 7, count: DigestKey.byteCount))!
    static let deskhandBundle = BundleID("com.birbhomes.deskhand")!

    static func app(_ bundleID: String, _ name: String, certain: Bool = true) -> ObservedApp {
        ObservedApp(identity: AppIdentity(bundleID: BundleID(bundleID), signer: .apple), name: name, isCertain: certain)
    }

    static let textEdit = app("com.apple.TextEdit", "TextEdit")
    static let notes = app("com.apple.Notes", "Notes")

    static let policy = AppPolicy(
        deskhandBundleID: deskhandBundle,
        allowed: [
            AllowedApp(bundleID: BundleID("com.apple.TextEdit")!, signer: .apple),
            AllowedApp(bundleID: BundleID("com.apple.Notes")!, signer: .apple),
        ])

    static let main = DisplayInfo(
        displayID: DisplayID(1), uuid: UUID(uuidString: "6B1B4C5E-0000-4000-8000-000000000001")!,
        name: "Built-in Retina Display", isMain: true, isBuiltin: true, asleep: false,
        bounds: GlobalRect(x: 0, y: 0, width: 1728, height: 1117), pixelSize: PixelSize(width: 3456, height: 2234),
        pointPixelScale: 2)
    static let side = DisplayInfo(
        displayID: DisplayID(2), uuid: UUID(uuidString: "6B1B4C5E-0000-4000-8000-000000000002")!,
        name: "Side Display", isMain: false, isBuiltin: false, asleep: false,
        bounds: GlobalRect(x: -1920, y: 0, width: 1920, height: 1080), pixelSize: PixelSize(width: 1920, height: 1080),
        pointPixelScale: 1)
    static let generation = DisplayConfigGeneration(4)

    static func signals(holding states: Set<BlockingState> = [], conditions: Set<Condition> = []) -> StateSignals {
        let fed: [PlatformSignal: BlockingState] = [
            .notConsole: .notConsole, .locked: .locked, .displayAsleep: .displayAsleep,
            .permissionMissing: .permissionMissing, .permissionStale: .permissionStale, .secureInput: .secureInput,
        ]
        var readings: [PlatformSignal: SignalReading] = [:]
        for signal in PlatformSignal.allCases {
            readings[signal] = fed[signal].map(states.contains) == true ? .present : .absent
        }
        if conditions.contains(.loginWindow) { readings[.loginWindow] = .present }
        let allowance: AllowanceVerdict =
            states.contains(.gated) ? .missing : .valid(expiresAt: t0.wall.adding(milliseconds: 365 * 86_400_000))
        return StateSignals(
            allowance: allowance, readings: readings, credentialsWarning: conditions.contains(.credentialsWarning),
            cleanupPending: conditions.contains(.cleanupPending), logUnavailable: conditions.contains(.logUnavailable),
            ownInput: .idle)
    }
}

final class ToolClock: Sendable {
    private let offsetMs = Mutex<Int64>(0)

    var reading: ClockReading { ToolFixture.t0.advanced(byMilliseconds: offsetMs.withLock { $0 }) }

    func advance(byMilliseconds milliseconds: Int64) { offsetMs.withLock { $0 += milliseconds } }
}

final class FakeDisplays: DisplayProvider {
    private let state = Mutex<(DisplayConfiguration, fault: Bool)>(
        (
            DisplayConfiguration(generation: ToolFixture.generation, displays: [ToolFixture.main, ToolFixture.side]),
            false
        ))

    var generation: DisplayConfigGeneration { state.withLock { $0.0.generation } }

    func configuration() throws(PlatformFault) -> DisplayConfiguration {
        let (configuration, fault) = state.withLock { ($0.0, $0.fault) }
        if fault { throw PlatformFault("The display list could not be read.") }
        return configuration
    }

    func reconfigure(_ displays: [DisplayInfo]? = nil) {
        state.withLock {
            $0.0 = DisplayConfiguration(
                generation: DisplayConfigGeneration($0.0.generation.rawValue + 1), displays: displays ?? $0.0.displays)
        }
    }

    func failReads(_ fail: Bool = true) { state.withLock { $0.fault = fail } }
}

final class FakeCapturer: ScreenCapturer {
    struct Behavior: Sendable {
        var imageBytes = 1000
        var tooLarge: Int?
        var fault = false
        var pointer: GlobalPoint? = GlobalPoint(x: 100, y: 50)
        var reportedSize: ScreenshotSize?
        var reportedEncoding: ImageEncoding?
        var during: (@Sendable () async -> Void)?
    }

    private let state = Mutex<(behavior: Behavior, requests: [CaptureRequest])>((Behavior(), []))

    var requests: [CaptureRequest] { state.withLock { $0.requests } }

    func configure(_ change: (inout Behavior) -> Void) { state.withLock { change(&$0.behavior) } }

    func capture(_ request: CaptureRequest) async throws(CaptureFailure) -> CapturedImage {
        let behavior = state.withLock {
            $0.requests.append(request)
            return $0.behavior
        }
        await behavior.during?()
        if behavior.fault { throw .failed(PlatformFault("The capture failed.")) }
        if let tooLarge = behavior.tooLarge { throw .imageTooLarge(imageBytes: tooLarge) }
        let size: ScreenshotSize
        do {
            size = try behavior.reportedSize ?? request.size
        } catch {
            throw .failed(PlatformFault("unsized"))
        }
        let output = size.output
        let pixels = FramePixels(size: output, rgb: Array(repeating: 90, count: output.width * output.height * 3))!
        let encoding: ImageEncoding = behavior.reportedEncoding ?? (request.format == .png ? .png : .jpeg(.q85))
        return CapturedImage(
            bytes: Array(repeating: 0xAB, count: behavior.imageBytes), encoding: encoding, size: size, pixels: pixels,
            pointerLocation: behavior.pointer)
    }
}

final class FakeDesk: IdentityMeasurer, UserActivitySource, EventPoster, KeyCodeMapper, ExecutionTimer,
    ExecutorObserver, TargetPatchVerifier
{
    struct World: Sendable {
        var frontmost = ToolFixture.textEdit
        var nextFrontmost: [ObservedApp] = []
        var underTarget: ObservedApp?
        var idleMs: Int? = 60_000
        var posted: [InputEvent] = []
        var released: [HeldInput] = []
        var releaseFails = false
        var patch: PatchVerdict = .unchanged
        var logAppends: [Bool] = []
        var onSleep: (@Sendable () async -> Void)?
    }

    let clock: ToolClock
    private let world = Mutex(World())

    init(clock: ToolClock) { self.clock = clock }

    func change(_ body: (inout World) -> Void) { world.withLock { body(&$0) } }
    func read<T: Sendable>(_ body: (World) -> T) -> T { world.withLock { body($0) } }

    var posted: [InputEvent] { read(\.posted) }
    var released: [HeldInput] { read(\.released) }

    func frontmostApp() -> ObservedApp {
        world.withLock { world in
            if !world.nextFrontmost.isEmpty { world.frontmost = world.nextFrontmost.removeFirst() }
            return world.frontmost
        }
    }

    func keyboardFocus() -> ObservedWindow { ObservedWindow(owner: read(\.frontmost), title: "notes.txt") }

    func windows(at points: [GlobalPoint]) -> [ObservedWindow] {
        let owner = read { $0.underTarget ?? $0.frontmost }
        return points.map { _ in ObservedWindow(owner: owner, title: "notes.txt") }
    }

    func idleMilliseconds() -> Int? { read(\.idleMs) }

    func post(_ event: InputEvent) throws { change { $0.posted.append(event) } }

    func postRelease(_ input: HeldInput) throws {
        let failed = world.withLock { world in
            if !world.releaseFails { world.released.append(input) }
            return world.releaseFails
        }
        if failed { throw PlatformFault("The release could not be posted.") }
    }

    func code(for key: Key) -> PostedKeyCode? { PostedKeyCode(UInt16(0x100 + Key.allCases.firstIndex(of: key)!)) }
    func code(for modifier: Modifier) -> PostedKeyCode {
        PostedKeyCode(UInt16(0x37 + Modifier.allCases.firstIndex(of: modifier)!))
    }
    var textCarrier: PostedKeyCode { PostedKeyCode(0x31) }

    func sleep(for duration: Duration) async {
        clock.advance(byMilliseconds: Int64((duration / .milliseconds(1)).rounded(.up)))
        let hook = world.withLock { world in
            defer { world.onSleep = nil }
            return world.onSleep
        }
        await hook?()
        await Task.yield()
    }

    func executionDidChange(executing: Bool) {}
    func didPostEvent(at instant: ContinuousClock.Instant) {}
    func actionLogDidAppend(succeeded: Bool) { change { $0.logAppends.append(succeeded) } }
    func cleanupPendingDidChange(_ pending: Bool) {}

    func verify(_ frame: LiveFrame, patches: [TargetPatch]) async -> [PatchVerdict] {
        let verdict = read(\.patch)
        return patches.map { _ in verdict }
    }
}

final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func increment() { count.withLock { $0 += 1 } }
}

final class MemoryStorage: OperationStorage, Sendable {
    private let bytes = Mutex<[UInt8]?>(nil)

    func read() throws(StorageError) -> [UInt8]? { bytes.withLock { $0 } }
    func append(_ more: [UInt8]) throws(StorageError) { bytes.withLock { $0 = ($0 ?? []) + more } }
    func synchronize() throws(StorageError) {}
    func replace(with bytes: [UInt8]) throws(StorageError) { self.bytes.withLock { $0 = bytes } }
}

final class MemoryStoreLoader: OperationStoreLoader, Sendable {
    private let lock = Mutex(())
    private let storage = MemoryStorage()

    func load(now: Timestamp) throws(OperationStoreLoadError) -> OperationStore {
        try lock.withLock { _ throws(OperationStoreLoadError) in
            try OperationStore(storage: storage, now: now)
        }
    }
}

final class MemoryLedgerStore: HeldInputStore, Sendable {
    private let bytes = Mutex<[UInt8]?>(nil)

    func load() throws -> [UInt8]? { bytes.withLock { $0 } }
    func replace(with bytes: [UInt8]) throws { self.bytes.withLock { $0 = bytes } }
}

struct ToolHarness {
    let clock = ToolClock()
    let displays = FakeDisplays()
    let capturer = FakeCapturer()
    let desk: FakeDesk
    let conditions = LiveConditions()
    let log = InMemoryActionLog()
    let owner: DeskOwner
    let executor: InputExecutor
    let dispatcher: DeskhandDispatcher
    let leaseChanges = Counter()

    init(limits: Limits = Limits(), armed: Bool = true, ledger: MemoryLedgerStore = MemoryLedgerStore()) throws {
        desk = FakeDesk(clock: clock)
        let clock = self.clock
        owner = DeskOwner(policy: ToolFixture.policy, displays: displays, clock: { clock.reading })
        let seams = InputExecutor.Seams(
            state: owner, frames: owner, patches: desk, identity: desk, activity: desk, poster: desk, keyCodes: desk,
            log: log, timer: desk, observer: desk, operationStore: MemoryStoreLoader())
        executor = InputExecutor(
            configuration: .init(limits: limits), seams: seams, ledger: try HeldInputLedger(store: ledger),
            now: clock.reading.wall)
        let counter = leaseChanges
        dispatcher = DeskhandDispatcher(
            configuration: .init(
                mac: "studio-mac", serverVersion: "0.1.0", startedAt: ToolFixture.t0.wall, limits: limits),
            owner: owner, executor: executor,
            platform: .init(capturer: capturer, identity: desk, activity: desk, conditions: conditions),
            digestKey: ToolFixture.digestKey, leaseDidChange: { counter.increment() })
        if armed { owner.reduce(signals: ToolFixture.signals(), command: .arm(for: .seconds(3600))) }
    }

    @discardableResult
    func hold(_ states: Set<BlockingState>, conditions: Set<Condition> = []) -> DeskOwner.Reduction {
        let command: ArmingCommand? =
            states.contains(.paused) ? .killSwitch : states.contains(.disarmed) ? .disarm : nil
        return owner.reduce(signals: ToolFixture.signals(holding: states, conditions: conditions), command: command)
    }

    func status(_ arguments: StatusArguments = StatusArguments(), caller: ToolCaller = ToolFixture.caller)
        async throws(ToolError) -> StatusResult
    {
        try await dispatcher.status(arguments, caller: caller)
    }

    @discardableResult
    func lease(
        _ command: LeaseCommand, holder: HolderID = ToolFixture.holder, caller: ToolCaller = ToolFixture.caller
    ) async throws(ToolError) -> LeaseToolResult {
        try await dispatcher.lease(LeaseArguments(holderID: holder, command: command), caller: caller)
    }

    static func shot(_ arguments: JSONObject = [:], holder: HolderID = ToolFixture.holder) -> ScreenshotArguments {
        var arguments = arguments
        arguments["holder_id"] = .string(holder.rawValue)
        return try! ScreenshotArguments(arguments: arguments)
    }

    func screenshot(_ arguments: ScreenshotArguments = shot(), caller: ToolCaller = ToolFixture.caller)
        async throws(ToolError) -> CapturedScreenshot
    {
        try await dispatcher.screenshot(arguments, caller: caller)
    }

    func check(
        _ frame: FrameID, holder: HolderID = ToolFixture.holder, caller: ToolCaller = ToolFixture.caller,
        use: FrameUse = .pointer
    ) async -> StaleFrameReason? {
        let scope = FrameScope(principal: caller.principal, holderID: holder)
        switch await owner.check(frame, in: scope, for: use, now: clock.reading.wall) {
        case .valid: return nil
        case .stale(let reason, _): return reason
        }
    }

    func type(
        _ text: String, frame: FrameID, operation: String = "op-1", holder: HolderID = ToolFixture.holder,
        caller: ToolCaller = ToolFixture.caller
    ) async throws -> EffectAnswer {
        let raw: JSONObject = [
            "holder_id": .string(holder.rawValue), "frame_id": .string(frame.rawValue),
            "operation_id": .string(operation), "action": ["type": "type", "text": .string(text)],
        ]
        return await dispatcher.effect(.keyboard(try KeyboardArguments(arguments: raw)), received: raw, caller: caller)
    }
}

extension EffectAnswer {
    var toolError: ToolError? {
        guard case .error(let error) = self else { return nil }
        return error
    }

    var code: ToolErrorCode? { toolError?.code }
}

extension ToolError {
    var operationView: OperationView? {
        switch operation {
        case .existing(let view)?, .result(let view)?, .replayed(let view, _)?: view
        case nil: nil
        }
    }
}

func refusal<T>(_ body: () async throws(ToolError) -> T) async -> ToolError? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}
