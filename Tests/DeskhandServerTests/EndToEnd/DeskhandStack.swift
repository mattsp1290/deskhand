import DeskhandCore
import DeskhandTestSupport
import Foundation
import NIOCore
import Synchronization

@testable import DeskhandServer

struct DeskhandStack: Sendable {
    struct Options: Sendable {
        var limits = Limits()
        var waitLimit = InputExecutor.Configuration.defaultWaitLimit
        var waitTimer: any WaitLimitTimer = TaskSleepTimer()
        var frameCheck: (@Sendable () async -> FrameCheck)?
        var armed = true
        var states: Set<BlockingState> = []
        var tokenOverlap: Duration = .zero
        var state: StateDirectory?
        var clock: ToolClock?
    }

    static let mac = "studio-mac"
    static let armingPeriod = Duration.seconds(3600)

    let options: Options
    let clock: ToolClock
    let platform: StackPlatform
    let state: StateDirectory
    let credentials: CredentialDirectory
    let log: FaultInjectingActionLog<StackActionLog>
    let reloader: CredentialReloader
    let conditions: LiveConditions
    let owner: DeskOwner
    let executor: InputExecutor
    let recovery: RecoveryReport
    let startedAt: Timestamp
    let stateOwner: StackStateOwner
    let watchdog: Watchdog
    let dispatcher: DeskhandDispatcher
    let listener: DeskhandListener
    let events: EventLog
    let address: SocketAddress
    let pki: TestPKI
    private let watchdogRun: Task<Void, Never>

    var desk: FakeDesk { platform.desk }

    static func start(_ options: Options = Options()) async throws -> DeskhandStack {
        let clock = options.clock ?? ToolClock()
        let platform = StackPlatform(clock: clock, states: options.states)
        let state = try options.state ?? StateDirectory()
        let credentials = try CredentialDirectory()
        let log = FaultInjectingActionLog(wrapping: StackActionLog())

        let reloader = try await CredentialReloader(
            configuration: credentials.configuration(tokenOverlap: options.tokenOverlap))
        let conditions = LiveConditions(credentialsWarning: { reloader.status.credentialsWarning })
        let posts = PostTimestampRecorder()
        let observer = StackObserver(conditions: conditions, posts: posts)
        let activity = PersonActivitySource(
            signal: platform.idle, posts: posts, clock: { clock.reading.monotonic })

        var built: DeskOwner?
        let recovered = await Recovery(
            ledgerStore: FileHeldInputStore(path: state.ledgerPath),
            configuration: InputExecutor.Configuration(
                actionsPerMinute: options.limits.actionsPerMinute, waitLimit: options.waitLimit)
        ).start(at: clock.reading) { world in
            let owner = DeskOwner(
                policy: ToolFixture.policy, displays: platform.displays, frames: world.frames, report: world.report,
                clock: { clock.reading })
            owner.reduce(signals: platform.signals(ownInput: observer.ownInput))
            built = owner
            return InputExecutor.Seams(
                state: owner, frames: StackFrames(owner: owner, check: options.frameCheck), patches: platform.desk,
                identity: platform.desk, activity: activity,
                poster: platform.desk, keyCodes: platform.desk, log: log, timer: platform.desk,
                waitTimer: options.waitTimer, observer: observer,
                operationStore: FileOperationStoreLoader(
                    path: state.recordsPath, configuration: OperationStore.Configuration(limits: options.limits)))
        }
        let owner = built!
        let executor = recovered.executor

        let stateOwner = StackStateOwner(owner: owner, executor: executor, platform: platform, observer: observer)
        let watchdog = Watchdog(
            owner: stateOwner, executor: executor, activity: activity, scheduler: FakeClockScheduler(clock: clock))
        stateOwner.watchdog.withLock { $0 = watchdog }
        let watchdogRun = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await watchdog.run() }
                group.addTask {
                    for await executing in observer.executionChanges {
                        await watchdog.executionDidChange(executing: executing)
                    }
                }
            }
        }

        let dispatcher = DeskhandDispatcher(
            configuration: .init(mac: mac, startedAt: recovered.world.startedAt, limits: options.limits),
            owner: owner, executor: executor,
            platform: .init(
                capturer: platform.capturer, identity: platform.desk, activity: activity, conditions: conditions),
            digestKey: ToolFixture.digestKey, leaseDidChange: { await watchdog.refreshState() })
        let events = EventLog()
        let listener = DeskhandListener(
            configuration: ListenerHarness.configuration(), tls: reloader.tlsContexts, tokens: reloader.tokens,
            handler: MCPHandler(dispatcher: dispatcher), events: { events.record($0) })
        let address: SocketAddress
        do {
            address = try await listener.start()
        } catch {
            watchdogRun.cancel()
            throw error
        }

        let stack = DeskhandStack(
            options: options, clock: clock, platform: platform, state: state, credentials: credentials, log: log,
            reloader: reloader, conditions: conditions, owner: owner, executor: executor, recovery: recovered.report,
            startedAt: recovered.world.startedAt, stateOwner: stateOwner, watchdog: watchdog, dispatcher: dispatcher,
            listener: listener, events: events, address: address, pki: try TestPKI.get(), watchdogRun: watchdogRun)
        if options.armed { await stack.arm() }
        return stack
    }

    static func with<T>(_ options: Options = Options(), _ body: (DeskhandStack) async throws -> T) async throws -> T {
        let stack = try await start(options)
        do {
            let result = try await body(stack)
            await stack.stop()
            return result
        } catch {
            await stack.stop()
            throw error
        }
    }

    func stop() async {
        await listener.stop()
        await reloader.stop()
        watchdogRun.cancel()
        await watchdogRun.value
    }

    func hold(_ states: Set<BlockingState>, conditions: Set<Condition> = []) async {
        platform.report(states, conditions: conditions)
        let command: ArmingCommand? =
            states.contains(.paused) ? .killSwitch : states.contains(.disarmed) ? .disarm : nil
        await stateOwner.change(command: command)
    }

    func arm() async { await stateOwner.change(command: .arm(for: Self.armingPeriod)) }

    var entries: [ActionLogEntry] { get async { await log.base.entries } }
}

final class StackStopHost: CleanStopHost {
    enum Step: Hashable, Sendable {
        case stopAccepting
        case dropLease
        case log
        case close
        case exit(Int32)
    }

    private let recorded = Mutex<(steps: [Step], report: CleanStopReport?)>(([], nil))

    var steps: [Step] { recorded.withLock { $0.steps } }
    var report: CleanStopReport? { recorded.withLock { $0.report } }

    func stopAcceptingCalls() async { recorded.withLock { $0.steps.append(.stopAccepting) } }
    func dropLeaseAndFrames() async { recorded.withLock { $0.steps.append(.dropLease) } }
    func logStop(_ report: CleanStopReport) {
        recorded.withLock {
            $0.steps.append(.log)
            $0.report = report
        }
    }
    func closeConnections() async { recorded.withLock { $0.steps.append(.close) } }

    func exit(_ status: Int32) { recorded.withLock { $0.steps.append(.exit(status)) } }
}

extension DeskhandStack {

    func cleanStop(host: StackStopHost) -> CleanStop {
        CleanStop(executor: executor, host: host, scheduler: FakeClockScheduler(clock: clock), exit: host.exit)
    }
}

final class StackStateOwner: WatchdogStateOwner {
    let owner: DeskOwner
    let executor: InputExecutor
    let platform: StackPlatform
    let observer: StackObserver
    let watchdog = Mutex<Watchdog?>(nil)

    init(owner: DeskOwner, executor: InputExecutor, platform: StackPlatform, observer: StackObserver) {
        self.owner = owner
        self.executor = executor
        self.platform = platform
        self.observer = observer
    }

    func snapshot() -> DeskSnapshot { owner.snapshot() }

    func reduceNow(allowanceChanged: Bool) async {
        await deliver(owner.reduce(signals: platform.signals(ownInput: observer.ownInput)))
    }

    func change(command: ArmingCommand?) async {
        await deliver(owner.reduce(signals: platform.signals(ownInput: observer.ownInput), command: command))
        await watchdog.withLock { $0 }?.refreshState()
    }

    private func deliver(_ reduction: DeskOwner.Reduction) async {
        for interruption in reduction.interruptions { await executor.interrupt(interruption) }
    }
}

final class StackObserver: ExecutorObserver {
    let conditions: LiveConditions
    let posts: PostTimestampRecorder
    let executionChanges: AsyncStream<Bool>
    private let execution: AsyncStream<Bool>.Continuation
    private let executing = Mutex(false)

    init(conditions: LiveConditions, posts: PostTimestampRecorder) {
        self.conditions = conditions
        self.posts = posts
        (executionChanges, execution) = AsyncStream.makeStream()
    }

    func executionDidChange(executing: Bool) {
        self.executing.withLock { $0 = executing }
        execution.yield(executing)
    }

    var ownInput: OwnInputActivity {
        OwnInputActivity(
            commandFromPostedEvent: false, operationExecuting: executing.withLock { $0 },
            lastPostedEvent: posts.lastPostedEvent)
    }

    func didPostEvent(at instant: ContinuousClock.Instant) { posts.didPostEvent(at: instant) }
    func actionLogDidAppend(succeeded: Bool) { conditions.actionLogDidAppend(succeeded: succeeded) }
    func cleanupPendingDidChange(_ pending: Bool) {}
}

final class StackPlatform: Sendable {
    let displays = FakeDisplays()
    let capturer = FakeCapturer()
    let desk: FakeDesk
    let idle: DeskIdleSignal
    private let reported: Mutex<(states: Set<BlockingState>, conditions: Set<Condition>)>

    init(clock: ToolClock, states: Set<BlockingState>) {
        desk = FakeDesk(clock: clock)
        idle = DeskIdleSignal(desk: desk)
        reported = Mutex((states, []))
    }

    func signals(ownInput: OwnInputActivity) -> StateSignals {
        let (states, conditions) = reported.withLock { ($0.states, $0.conditions) }
        var signals = ToolFixture.signals(holding: states, conditions: conditions)
        signals.ownInput = ownInput
        return signals
    }

    func report(_ states: Set<BlockingState>, conditions: Set<Condition>) {
        reported.withLock { $0 = (states, conditions) }
    }
}

struct DeskIdleSignal: IdleSignalSource {
    let desk: FakeDesk

    func idleSignal() -> IdleSignal {
        desk.read(\.idleMs).map { .personOnly(.milliseconds($0)) } ?? .unavailable
    }
}

struct FakeClockScheduler: WatchdogScheduler {
    let clock: ToolClock

    var now: ContinuousClock.Instant { clock.reading.monotonic }

    func sleep(until deadline: ContinuousClock.Instant) async {
        while clock.reading.monotonic < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

struct StateDirectory: Sendable {
    let directory: URL

    var recordsPath: String { directory.appendingPathComponent("operations.journal").path }
    var ledgerPath: String { directory.appendingPathComponent("held-input.ledger").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskhand-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func copy() throws -> StateDirectory {
        let copy = try StateDirectory()
        for (from, to) in [(recordsPath, copy.recordsPath), (ledgerPath, copy.ledgerPath)] {
            guard let bytes = FileManager.default.contents(atPath: from) else { continue }
            guard FileManager.default.createFile(atPath: to, contents: bytes, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        return copy
    }
}
