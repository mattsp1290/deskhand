import DeskhandCore
import DeskhandTestSupport
import Synchronization
import Testing

enum WatchdogFixture {
    static let t0 = ExecutorFixture.t0

    /// Both clocks `milliseconds` after ``t0``.
    static func at(_ milliseconds: Int64) -> ClockReading { t0.advanced(byMilliseconds: milliseconds) }

    /// The reading whose monotonic clock shows `instant`, with the wall clock moved as far.
    static func reading(at instant: ContinuousClock.Instant) -> ClockReading {
        let milliseconds = Int64((t0.monotonic.duration(to: instant) / .milliseconds(1)).rounded(.down))
        return ClockReading(wall: t0.wall.adding(milliseconds: milliseconds), monotonic: instant)
    }

    static func milliseconds(since start: ContinuousClock.Instant, to instant: ContinuousClock.Instant) -> Int64 {
        Int64((start.duration(to: instant) / .milliseconds(1)).rounded(.down))
    }
}

/// A monotonic clock that moves only when the test moves it. A sleeper wakes when the clock passes
/// its deadline or its task is cancelled; ``waitForSleepers(_:)`` waits until that many are asleep.
final class ManualScheduler: WatchdogScheduler {
    private struct Sleeper {
        let id: UInt64
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: ContinuousClock.Instant
        var sleepers: [Sleeper] = []
        var cancelled: Set<UInt64> = []
        var lastID: UInt64 = 0
    }

    private let state: Mutex<State>
    private let waiters = Waiters()

    init(now: ContinuousClock.Instant = WatchdogFixture.t0.monotonic) { state = Mutex(State(now: now)) }

    var now: ContinuousClock.Instant { state.withLock(\.now) }

    var reading: ClockReading { WatchdogFixture.reading(at: now) }

    /// Milliseconds since ``WatchdogFixture/t0``.
    var elapsedMs: Int64 { WatchdogFixture.milliseconds(since: WatchdogFixture.t0.monotonic, to: now) }

    var sleeperDeadlines: [ContinuousClock.Instant] { state.withLock { $0.sleepers.map(\.deadline) } }

    func sleep(until deadline: ContinuousClock.Instant) async {
        let id = state.withLock { state in
            state.lastID += 1
            return state.lastID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let asleep = state.withLock { state in
                    if deadline <= state.now || state.cancelled.contains(id) { return false }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return true
                }
                if asleep { waiters.changed() } else { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                state.cancelled.insert(id)
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume()
            waiters.changed()
        }
    }

    /// Moves the clock to `instant`, never back, and wakes every sleeper it reached.
    func advance(to instant: ContinuousClock.Instant) {
        let due = state.withLock { state in
            state.now = max(state.now, instant)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
        waiters.changed()
    }

    func advance(byMilliseconds milliseconds: Int64) { advance(to: now.advanced(by: .milliseconds(milliseconds))) }

    /// Returns once at least `count` tasks sleep on this clock, or the calling task is cancelled.
    func waitForSleepers(_ count: Int) async { await waitUntil { $0.count >= count } }

    /// Returns once the deadlines of the tasks asleep on this clock satisfy `condition`, or the
    /// calling task is cancelled.
    func waitUntil(_ condition: @escaping @Sendable ([ContinuousClock.Instant]) -> Bool) async {
        await waiters.wait { [self] in condition(sleeperDeadlines) }
    }
}

/// The state's owner on a manual clock: a report, the signals it was reduced from, the lease, and
/// the allowance file, which a reduction reads into the signals when told the file changed or when
/// its copy is a second old (contract 14.4).
final class FakeDesk: WatchdogStateOwner {
    struct World: Sendable {
        var report: StateReport
        var signals: StateSignals
        var leases: LeaseManager
        var allowanceFile: AllowanceVerdict
        var allowanceReadAt: ContinuousClock.Instant
        /// Each reduction's time and whether it bypassed the copy.
        var reductions: [(ContinuousClock.Instant, Bool)] = []
    }

    let clock: ManualScheduler
    let world: Mutex<World>
    private let reduced = Waiters()

    /// Armed for `armedMs`, with an allowance that expires `allowanceMs` after t0 (none when `nil`),
    /// and a lease acquired at t0 for `leaseTTLMs` (none when `nil`).
    init(clock: ManualScheduler, armedMs: Int64 = 3_600_000, allowanceMs: Int64? = 600_000, leaseTTLMs: Int? = nil) {
        self.clock = clock
        let t0 = WatchdogFixture.t0
        var signals = StateFixture.signals()
        signals.allowance = allowanceMs.map { .valid(expiresAt: t0.wall.adding(milliseconds: $0)) } ?? .missing
        let report = StateReducer.reduce(
            previous: .startup, signals: signals, command: .arm(for: .milliseconds(armedMs)), now: t0
        ).report
        let leases = leaseTTLMs.map { ExecutorFixture.acquired(ttlMs: $0, at: t0) } ?? LeaseManager()
        world = Mutex(
            World(
                report: report, signals: signals, leases: leases, allowanceFile: signals.allowance,
                allowanceReadAt: t0.monotonic))
    }

    func read<T: Sendable>(_ body: (World) -> T) -> T { world.withLock { body($0) } }

    func change(_ body: (inout World) -> Void) { world.withLock { body(&$0) } }

    func snapshot() -> DeskSnapshot {
        let reading = clock.reading
        return read {
            DeskSnapshot(reading: reading, report: $0.report, lease: $0.leases, policy: ExecutorFixture.policy)
        }
    }

    func reduceNow(allowanceChanged: Bool) async {
        let now = clock.reading
        change { world in
            if allowanceChanged || world.allowanceReadAt.duration(to: now.monotonic) >= .seconds(1) {
                world.signals.allowance = world.allowanceFile
                world.allowanceReadAt = now.monotonic
            }
            let step = StateReducer.reduce(previous: world.report, signals: world.signals, now: now)
            world.report = step.report
            for case .dropLease(let state) in step.effects { _ = world.leases.drop(because: state, now: now) }
            _ = world.leases.expire(now: now)
            world.reductions.append((now.monotonic, allowanceChanged))
        }
        reduced.changed()
    }

    /// Returns once `count` reductions have run, or the calling task is cancelled.
    func waitForReductions(_ count: Int) async { await reduced.wait { self.read(\.reductions.count) >= count } }

    func renewLease(ttlMs: Int) {
        let now = clock.reading
        change {
            _ = $0.leases.apply(
                LeaseArguments(holderID: ExecutorFixture.holder, command: .renew(ttlMs: ttlMs)),
                principal: ExecutorFixture.principal, state: .ok, now: now)
        }
    }
}

/// Records what the watchdog asks of the executor, with the manual clock's time of each request.
actor FakeExecutor: WatchdogExecutor {
    let clock: ManualScheduler
    private(set) var interrupts: [(Interruption, Int64)] = []
    private(set) var cleanupRetries: [Int64] = []
    var nextRetry: ContinuousClock.Instant?
    /// What ``isExecuting`` answers.
    private(set) var executing = false
    private nonisolated let interruptCount = Mutex(0)
    private nonisolated let arrivals = Waiters()

    init(clock: ManualScheduler) { self.clock = clock }

    var isExecuting: Bool { executing }

    func setExecuting(_ executing: Bool) { self.executing = executing }

    func interrupt(_ interruption: Interruption) {
        interrupts.append((interruption, clock.elapsedMs))
        interruptCount.withLock { $0 += 1 }
        arrivals.changed()
    }

    /// Returns once at least `count` interruptions arrived, or the calling task is cancelled.
    nonisolated func waitForInterrupts(_ count: Int) async {
        await arrivals.wait { self.interruptCount.withLock { $0 } >= count }
    }

    func retryCleanup(now: ClockReading) -> OwedRelease? {
        cleanupRetries.append(clock.elapsedMs)
        return nil
    }

    func nextCleanupRetry(at now: ClockReading) -> ContinuousClock.Instant? { nextRetry }

    func setNextRetry(_ instant: ContinuousClock.Instant?) { nextRetry = instant }

    var interruptions: [Interruption] { interrupts.map(\.0) }

    /// When the first interruption satisfying `matches` arrived, in milliseconds since t0.
    func firstInterrupt(where matches: (Interruption) -> Bool) -> Int64? { interrupts.first { matches($0.0) }?.1 }
}

/// The Mac's input hardware as the idle signal sees it: the person's latest input, and, for a
/// signal that counts them, deskhand's own events.
final class FakeHID: IdleSignalSource {
    enum Kind: Sendable {
        case personOnly
        case anyOrigin
        case unavailable
    }

    private struct State {
        var kind: Kind
        var person: ContinuousClock.Instant
        var own: ContinuousClock.Instant?
        var reads = 0
    }

    private let state: Mutex<State>
    private let clock: @Sendable () -> ContinuousClock.Instant

    /// The person last touched the Mac a minute before `clock()` first reads.
    init(_ kind: Kind, clock: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.clock = clock
        state = Mutex(State(kind: kind, person: clock().advanced(by: .seconds(-60))))
    }

    var reads: Int { state.withLock(\.reads) }

    func setKind(_ kind: Kind) { state.withLock { $0.kind = kind } }

    func personInput(at instant: ContinuousClock.Instant) { state.withLock { $0.person = max($0.person, instant) } }

    func ownEvent(at instant: ContinuousClock.Instant) {
        state.withLock { $0.own = max($0.own ?? instant, instant) }
    }

    func idleSignal() -> IdleSignal {
        let now = clock()
        return state.withLock { state in
            state.reads += 1
            switch state.kind {
            case .unavailable: return .unavailable
            case .personOnly: return .personOnly(state.person.duration(to: now))
            case .anyOrigin: return .anyOrigin(max(state.person, state.own ?? state.person).duration(to: now))
            }
        }
    }
}

/// deskhand's posts as the platform would report them: to the post recorder through the
/// executor's observer, and to the hardware.
struct OwnPosts {
    let recorder = PostTimestampRecorder()
    let hid: FakeHID

    func post(at instant: ContinuousClock.Instant) {
        recorder.didPostEvent(at: instant)
        hid.ownEvent(at: instant)
    }
}

/// A file watch the test fires by hand.
final class FakeFileWatch: FileChangeSource {
    private let streams = Mutex<[AsyncStream<Void>.Continuation]>([])
    private let watchers = Waiters()

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        streams.withLock { $0.append(continuation) }
        watchers.changed()
        return stream
    }

    /// Returns once something watches, or the calling task is cancelled.
    func waitUntilWatched() async { await watchers.wait { !self.streams.withLock(\.isEmpty) } }

    func fire() {
        for stream in streams.withLock({ $0 }) { stream.yield() }
    }
}

/// `lstat` signatures the test sets per path.
final class FakeSignatures: Sendable {
    private let signatures = Mutex<[String: PathSignature]>([:])
    private let lookups = Mutex(0)

    var lookupCount: Int { lookups.withLock { $0 } }

    func set(_ path: String, inode: UInt64?) {
        signatures.withLock {
            $0[path] = inode.map {
                PathSignature(
                    device: 1, inode: $0, mode: 0o100644, owner: 0, size: 120, modified: 1, modifiedNanoseconds: 0,
                    changed: 1, changedNanoseconds: 0)
            }
        }
    }

    func signature(_ path: String) -> PathSignature? {
        lookups.withLock { $0 += 1 }
        return signatures.withLock { $0[path] }
    }
}

/// The real executor on a fake Mac, built with a ``PersonActivitySource`` over a fake idle signal
/// and an observer that reports every post to the recorder and the hardware, with a watchdog over
/// both. The watchdog's owner is the fake Mac, whose clock moves by the executor's waits.
struct ExecutorWatch {
    let mac: FakeMac
    let hid: FakeHID
    let posts: OwnPosts
    let frames: FakeFrames
    let executor: InputExecutor
    let watchdog: Watchdog

    init(
        _ kind: FakeHID.Kind, mac: FakeMac = FakeMac(), configuration: Watchdog.Configuration = .init()
    ) throws {
        self.mac = mac
        let hid = FakeHID(kind) { mac.reading.monotonic }
        self.hid = hid
        posts = OwnPosts(hid: hid)
        frames = FakeFrames()
        let activity = PersonActivitySource(signal: hid, posts: posts.recorder) { mac.reading.monotonic }
        let seams = InputExecutor.Seams(
            state: mac, frames: frames, patches: FakePatches(mac: mac), identity: mac, activity: activity,
            poster: mac, keyCodes: mac, log: InMemoryActionLog(), timer: mac, waitTimer: ManualWaitLimits(),
            observer: ReportingObserver(mac: mac, posts: posts), operationStore: FakeStoreLoader())
        executor = InputExecutor(
            seams: seams, ledger: try HeldInputLedger(store: mac.ledgerStore), now: mac.reading.wall)
        watchdog = Watchdog(
            owner: MacOwner(mac: mac), executor: executor, activity: activity, scheduler: ManualScheduler(),
            configuration: configuration)
    }

    func call(_ action: JSONValue, operation: String = "op-1") throws -> EffectCall {
        let arguments: JSONObject = [
            "holder_id": .string(ExecutorFixture.holder.rawValue), "frame_id": .string(frames.frameID.rawValue),
            "operation_id": .string(operation), "action": action,
        ]
        let isPointer = action["x"] != nil || action["path"] != nil
        return EffectCall(
            principal: ExecutorFixture.principal, nodeAddress: ExecutorFixture.node,
            arguments: isPointer
                ? .pointer(try PointerArguments(arguments: arguments))
                : .keyboard(try KeyboardArguments(arguments: arguments)),
            digest: try RequestDigest(
                tool: isPointer ? .pointer : .keyboard, arguments: arguments, key: ExecutorFixture.digestKey),
            connection: FakeConnection())
    }

    /// The person touches the Mac `milliseconds` from the fake Mac's now, which moves there.
    func personActs(afterMilliseconds milliseconds: Int64) -> ContinuousClock.Instant {
        mac.advance(byMilliseconds: milliseconds)
        let instant = mac.reading.monotonic
        hid.personInput(at: instant)
        return instant
    }
}

/// The fake Mac's observer, with each post also reported as the platform would report it.
struct ReportingObserver: ExecutorObserver {
    let mac: FakeMac
    let posts: OwnPosts

    func executionDidChange(executing: Bool) { mac.executionDidChange(executing: executing) }

    func didPostEvent(at instant: ContinuousClock.Instant) { posts.post(at: instant) }

    func actionLogDidAppend(succeeded: Bool) { mac.actionLogDidAppend(succeeded: succeeded) }

    func cleanupPendingDidChange(_ pending: Bool) { mac.cleanupPendingDidChange(pending) }
}

/// The fake Mac as the watchdog's state owner: its state changes only when the test changes it.
final class MacOwner: WatchdogStateOwner {
    let mac: FakeMac
    private let count = Mutex(0)

    init(mac: FakeMac) { self.mac = mac }

    var reductions: Int { count.withLock { $0 } }

    func snapshot() -> DeskSnapshot { mac.snapshot() }

    func reduceNow(allowanceChanged: Bool) async { count.withLock { $0 += 1 } }
}

/// The state's owner judging the allowance through the real ``AllowanceCache`` on a manual clock,
/// so a reduction that does not drop the copy reads the file only when the copy is a second old.
/// The owner can be late: each reduction then reaches the file `lateMs` after the watchdog asked.
final class CacheDesk: WatchdogStateOwner {
    struct World: Sendable {
        var report: StateReport
        var signals: StateSignals
        var leases: LeaseManager
        var cache: AllowanceCache
        var lateMs: Int64 = 0
        /// When each reduction reached the cache, in milliseconds since t0.
        var reductions: [Int64] = []
    }

    static let valid = AllowanceSample.opened(contents: AllowanceSample.json(expiresAt: "\"2026-11-14T23:00:00Z\""))

    let clock: ManualScheduler
    let probe = FakeAllowanceProbe(CacheDesk.valid)
    let world: Mutex<World>

    /// Armed for an hour with a valid allowance, and a lease held for two minutes.
    init(clock: ManualScheduler) {
        self.clock = clock
        let t0 = WatchdogFixture.t0
        var signals = StateFixture.signals()
        var cache = AllowanceCache(reader: AllowanceSample.reader(probe))
        signals.allowance = cache.verdict(now: t0.wall, at: t0.monotonic)
        let report = StateReducer.reduce(
            previous: .startup, signals: signals, command: .arm(for: .seconds(3600)), now: t0
        ).report
        world = Mutex(
            World(
                report: report, signals: signals, leases: ExecutorFixture.acquired(ttlMs: 120_000, at: t0),
                cache: cache))
    }

    func removeFile() { probe.set(.fileFailed(directory: AllowanceSample.rootDirectory, error: .notFound)) }

    func setLate(_ milliseconds: Int64) { world.withLock { $0.lateMs = milliseconds } }

    var fileReads: Int { probe.calls.count }

    func snapshot() -> DeskSnapshot {
        let reading = clock.reading
        return world.withLock {
            DeskSnapshot(reading: reading, report: $0.report, lease: $0.leases, policy: ExecutorFixture.policy)
        }
    }

    func reduceNow(allowanceChanged: Bool) async {
        let late = world.withLock(\.lateMs)
        if late > 0 { clock.advance(byMilliseconds: late) }
        let now = clock.reading
        world.withLock { world in
            if allowanceChanged { world.cache.invalidate() }
            world.signals.allowance = world.cache.verdict(now: now.wall, at: now.monotonic)
            let step = StateReducer.reduce(previous: world.report, signals: world.signals, now: now)
            world.report = step.report
            for case .dropLease(let state) in step.effects { _ = world.leases.drop(because: state, now: now) }
            _ = world.leases.expire(now: now)
            world.reductions.append(clock.elapsedMs)
        }
    }
}
