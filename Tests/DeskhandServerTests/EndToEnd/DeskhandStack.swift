import DeskhandCore
import DeskhandTestSupport
import Foundation
import NIOCore
import Synchronization

@testable import DeskhandServer

/// deskhand composed in this process the way the app composes it (deskhand-6d91 starts from this),
/// served over loopback mutual TLS. Only the platform is fake: the displays, the capturer, the
/// frontmost-app and window readings, the idle signal, the event poster, the state signals and the
/// allowance verdict. The credential reload, the listener, the MCP layer, the dispatcher, the desk
/// owner, recovery, the executor with its real record file and ledger file, and the watchdog are
/// the production types.
///
/// Build order: credentials, then the per-Mac owner and the executor through ``Recovery``, then the
/// state owner and the watchdog on them, then the dispatcher, the MCP handler and the listener.
struct DeskhandStack: Sendable {
    struct Options: Sendable {
        var limits = Limits()
        /// A person arms deskhand from the menu bar once it is up.
        var armed = true
        /// What the platform reports at start.
        var states: Set<BlockingState> = []
        var tokenOverlap: Duration = .zero
        /// A restart passes the previous run's files and clock.
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
    let log: FaultInjectingActionLog<InMemoryActionLog>
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
    /// The watchdog and the execution changes it is told about, until ``stop()``.
    private let watchdogRun: Task<Void, Never>

    var desk: FakeDesk { platform.desk }

    static func start(_ options: Options = Options()) async throws -> DeskhandStack {
        let clock = options.clock ?? ToolClock()
        let platform = StackPlatform(clock: clock, states: options.states)
        let state = try options.state ?? StateDirectory()
        let credentials = try CredentialDirectory()
        let log = FaultInjectingActionLog(wrapping: InMemoryActionLog())

        let reloader = try await CredentialReloader(
            configuration: credentials.configuration(tokenOverlap: options.tokenOverlap))
        let conditions = LiveConditions(credentialsWarning: { reloader.status.credentialsWarning })
        let posts = PostTimestampRecorder()
        let observer = StackObserver(conditions: conditions, posts: posts)
        let activity = PersonActivitySource(
            signal: platform.idle, posts: posts, clock: { clock.reading.monotonic })

        // The owner is built inside the seams closure from the recovered world, and reduces its first
        // platform reading there, so recovery's first release attempt is judged on the real state.
        var built: DeskOwner?
        let recovered = await Recovery(
            ledgerStore: FileHeldInputStore(path: state.ledgerPath),
            configuration: InputExecutor.Configuration(limits: options.limits)
        ).start(at: clock.reading) { world in
            let owner = DeskOwner(
                policy: ToolFixture.policy, displays: platform.displays, frames: world.frames, report: world.report,
                clock: { clock.reading })
            owner.reduce(signals: platform.signals(ownInput: observer.ownInput))
            built = owner
            return InputExecutor.Seams(
                state: owner, frames: owner, patches: platform.desk, identity: platform.desk, activity: activity,
                poster: platform.desk, keyCodes: platform.desk, log: log, timer: platform.desk, observer: observer,
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

    /// Runs `body` on a started stack and stops it afterwards, whether or not `body` throws.
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

    // MARK: The person and the platform

    /// The platform now reports exactly `states` (and `conditions`), as when a signal changes.
    func hold(_ states: Set<BlockingState>, conditions: Set<Condition> = []) async {
        platform.report(states, conditions: conditions)
        let command: ArmingCommand? =
            states.contains(.paused) ? .killSwitch : states.contains(.disarmed) ? .disarm : nil
        await stateOwner.change(command: command)
    }

    /// A person arms deskhand from the menu bar.
    func arm() async { await stateOwner.change(command: .arm(for: Self.armingPeriod)) }

    /// The action log as the writer committed it.
    var entries: [ActionLogEntry] { get async { await log.base.entries } }
}

/// The process stop's host over a running stack (contract 15.2). It records the steps and leaves
/// the listener up, so a test sees what the listener does on its own with the calls a stop ended,
/// and can still read over the wire afterwards.
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
    /// The process exit, which a test's stop only records.
    func exit(_ status: Int32) { recorded.withLock { $0.steps.append(.exit(status)) } }
}

extension DeskhandStack {
    /// The clean stop over this stack, its deadline on the stack's clock, which only an executing
    /// operation's waits or the test move: no step runs out of time on a slow machine.
    func cleanStop(host: StackStopHost) -> CleanStop {
        CleanStop(executor: executor, host: host, scheduler: FakeClockScheduler(clock: clock), exit: host.exit)
    }
}

/// The state owner the app runs (deskhand-qbi7's role): it reads the platform's signals, reduces
/// them through the ``DeskOwner``, and passes each reduction's interruptions to the executor at
/// once, so a state that ends again before the watchdog looks still aborts the effect (contract
/// 10.3). It waits for nothing else of the executor: the watchdog's executor loop posts the
/// releases a reduction allows.
final class StackStateOwner: WatchdogStateOwner {
    let owner: DeskOwner
    let executor: InputExecutor
    let platform: StackPlatform
    let observer: StackObserver
    /// Set once the watchdog exists; it needs this owner first.
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

    /// A signal changed, or a person used the menu bar.
    func change(command: ArmingCommand?) async {
        await deliver(owner.reduce(signals: platform.signals(ownInput: observer.ownInput), command: command))
        await watchdog.withLock { $0 }?.refreshState()
    }

    private func deliver(_ reduction: DeskOwner.Reduction) async {
        for interruption in reduction.interruptions { await executor.interrupt(interruption) }
    }
}

/// What the executor reports, fanned out to the owners of the conditions, the person's activity
/// and the watchdog. Called on the executor without waiting, so execution changes reach the
/// watchdog through one stream, in order: a task per change could deliver an end before its start
/// and leave the watchdog polling the person while nothing executes.
final class StackObserver: ExecutorObserver {
    let conditions: LiveConditions
    let posts: PostTimestampRecorder
    /// Drained by one task into ``Watchdog/executionDidChange(executing:)``.
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

    /// What deskhand is doing with input, for the rule that only a person arms (contract 10.4). In
    /// this stack every arming command comes from the test, never from a posted event.
    var ownInput: OwnInputActivity {
        OwnInputActivity(
            commandFromPostedEvent: false, operationExecuting: executing.withLock { $0 },
            lastPostedEvent: posts.lastPostedEvent)
    }

    func didPostEvent(at instant: ContinuousClock.Instant) { posts.didPostEvent(at: instant) }
    func actionLogDidAppend(succeeded: Bool) { conditions.actionLogDidAppend(succeeded: succeeded) }
    /// `status` reads the executor's ledger directly.
    func cleanupPendingDidChange(_ pending: Bool) {}
}

/// The fake Mac: what the platform module provides in the app.
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

    /// The signals and the allowance verdict as the platform reads them now, with what deskhand
    /// itself is doing with input.
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

/// The idle signal the platform reads, from the fake desk's idle time.
struct DeskIdleSignal: IdleSignalSource {
    let desk: FakeDesk

    func idleSignal() -> IdleSignal {
        desk.read(\.idleMs).map { .personOnly(.milliseconds($0)) } ?? .unavailable
    }
}

/// The watchdog's timer on the fake clock: a wakeup is due once a test or an executing operation
/// has moved the clock past it.
struct FakeClockScheduler: WatchdogScheduler {
    let clock: ToolClock

    var now: ContinuousClock.Instant { clock.reading.monotonic }

    func sleep(until deadline: ContinuousClock.Instant) async {
        while clock.reading.monotonic < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// The directory of the operation records and the held-input ledger: owner-only, as
/// ``DurableFile`` requires.
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

    /// The files as they are on disk now, in a directory of their own: what a crash at this
    /// instant leaves for the next start, while this run goes on with its own.
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
