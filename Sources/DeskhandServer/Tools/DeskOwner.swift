import DeskhandCore
import Synchronization

/// The per-Mac world that the tools, the executor and the state reduction share: the latest
/// ``StateReport``, the one ``LeaseManager``, the app policy and the ``FrameStore`` (contract 4, 5,
/// 10). It is the executor's ``StateSource`` and ``FrameSource``.
///
/// One instance per Mac, behind one lock rather than an actor, because the executor reads
/// ``snapshot()`` between the ledger write and the post of every event and must not wait. Every
/// read and every change happens under that lock at one clock reading, so a reduction, the lease
/// it drops and the frames it invalidates change together: no `lease` call, screenshot or effect
/// can see one without the others.
public final class DeskOwner: StateSource, FrameSource {
    private struct World {
        var report: StateReport
        var lease = LeaseManager()
        var frames: FrameStore
        var policy: AppPolicy
        /// The state that last invalidated every frame, which names the refusal of a screenshot
        /// that was in flight then (contract 10.3).
        var invalidatedBy: BlockingState?
    }

    /// The Mac's displays: their generation is part of every frame check.
    public let displays: any DisplayProvider
    public let stateConfiguration: StateConfiguration
    private let clock: @Sendable () -> ClockReading
    private let world: Mutex<World>

    /// - Parameters:
    ///   - report: ``StateReport/startup`` at start; every later report comes from ``reduce(signals:command:)``.
    ///   - clock: read once inside every call; ``ClockReading/now()`` outside tests.
    public init(
        policy: AppPolicy, displays: any DisplayProvider, stateConfiguration: StateConfiguration = .standard,
        frames: FrameStore = FrameStore(), report: StateReport = .startup,
        clock: @escaping @Sendable () -> ClockReading = { ClockReading.now() }
    ) {
        self.displays = displays
        self.stateConfiguration = stateConfiguration
        self.clock = clock
        world = Mutex(World(report: report, frames: frames, policy: policy))
    }

    // MARK: StateSource and FrameSource

    public func snapshot() -> DeskSnapshot {
        world.withLock { world in
            DeskSnapshot(reading: clock(), report: world.report, lease: world.lease, policy: world.policy)
        }
    }

    public func check(_ id: FrameID, in scope: FrameScope, for use: FrameUse, now: Timestamp) async -> FrameCheck {
        let generation = displays.generation
        return world.withLock {
            $0.frames.check(id, in: scope, for: use, displayConfigGeneration: generation, now: now)
        }
    }

    // MARK: The state owner's side

    /// What one reduction changed, and what its caller still has to carry out against the executor.
    public struct Reduction: Sendable {
        public let report: StateReport
        /// In order (``TransitionEffect``). ``TransitionEffect/invalidateFrames`` and
        /// ``TransitionEffect/dropLease(_:)`` are already applied here.
        public let effects: [TransitionEffect]
        /// Every live lease this reduction ended, by running out or by a state that drops it.
        public let leaseEnds: [LeaseEnd]
        public let reading: ClockReading

        /// What stops the executing effect: pass each to ``InputExecutor/interrupt(_:)``.
        public var interruptions: [Interruption] {
            var found: [Interruption] = []
            for case .cancelInFlight(let state) in effects { found.append(.state(state)) }
            return found + leaseEnds.map(Interruption.leaseEnded)
        }

        /// The releases owed may be posted now: call ``InputExecutor/retryCleanup(now:)``.
        public var releasesHeldInput: Bool { effects.contains(.releaseHeldInput) }
    }

    /// Reduces `signals` (and a person's arming `command`) from the current report at the current
    /// reading, settles a lease that has run out, drops the lease and invalidates every frame as
    /// the effects require, all under one lock. The app's state owner calls it from
    /// ``WatchdogStateOwner/reduceNow(allowanceChanged:)``, then forwards ``Reduction/interruptions``
    /// to the executor and calls ``Watchdog/refreshState()``.
    ///
    /// `signals` is read under the lock, so reductions apply in the order their readings were
    /// taken: a reduction that read the signals before a newer one cannot apply after it and
    /// reopen a state the newer one closed. It must not call back into this owner.
    @discardableResult
    public func reduce(signals: @autoclosure () -> StateSignals, command: ArmingCommand? = nil) -> Reduction {
        world.withLock { world in
            let reading = clock()
            let (report, effects) = StateReducer.reduce(
                previous: world.report, signals: signals(), command: command, configuration: stateConfiguration,
                now: reading)
            world.report = report
            var ends: [LeaseEnd] = []
            if let end = world.lease.expire(now: reading) { ends.append(end) }
            for effect in effects {
                switch effect {
                case .cancelInFlight(let state): world.invalidatedBy = state
                case .invalidateFrames: world.frames.invalidateAll()
                case .dropLease(let state):
                    if let end = world.lease.drop(because: state, now: reading) { ends.append(end) }
                case .releaseHeldInput: break
                }
            }
            return Reduction(report: report, effects: effects, leaseEnds: ends, reading: reading)
        }
    }

    /// Replaces the app policy, for a configuration reload. The next check of every call uses it.
    public func updatePolicy(_ policy: AppPolicy) { world.withLock { $0.policy = policy } }

    // MARK: The tools' side

    /// The lease as `holder` sees it now (contract 5.4), and the rest of what `status` reports, at
    /// one reading. Changes nothing.
    func statusView(for holder: LeaseHolder?) -> StatusView {
        world.withLock { world in
            let reading = clock()
            let active = world.report.activeStates(at: reading)
            let lease: LeaseView? = holder.map { holder in
                // A lease that a state dropping it has outlived is gone, though the reduction that
                // drops it has not run yet (contract 10.4).
                guard Self.droppingState(in: active) == nil else { return .notHeldByCaller }
                return world.lease.view(for: holder, now: reading)
            }
            return StatusView(
                reading: reading, activeStates: active, conditions: world.report.conditions,
                armedUntil: world.report.armedUntil(at: reading), lease: lease)
        }
    }

    /// Runs one `lease` call at the state in force (contract 5). A lease that a state began by the
    /// clock alone has dropped is settled first, as the next reduction would.
    func applyLease(_ arguments: LeaseArguments, principal: Principal) -> (result: LeaseToolResult, ended: [LeaseEnd]) {
        world.withLock { world in
            let reading = clock()
            let state = world.report.state(at: reading)
            var ended: [LeaseEnd] = []
            if let dropping = Self.droppingState(in: world.report.activeStates(at: reading)),
                let end = world.lease.drop(because: dropping, now: reading)
            {
                ended.append(end)
            }
            let application = world.lease.apply(arguments, principal: principal, state: state, now: reading)
            if let end = application.ended { ended.append(end) }
            return (application.result, ended)
        }
    }

    /// What a capture starts from: the reading, the state, the policy and the frame epoch, which a
    /// change of state away from `ok` moves before the capture can be recorded.
    func beginCapture() -> CaptureStart {
        world.withLock { world in
            let reading = clock()
            return CaptureStart(
                reading: reading, state: world.report.state(at: reading), policy: world.policy,
                epoch: world.frames.epoch)
        }
    }

    /// Mints the frame of a finished capture for `scope`, unless the state left `ok` since it
    /// started: the screenshot is then refused with that state's name and mints nothing (contract 10.3).
    func record(_ capture: FrameCapture, for scope: FrameScope, startedIn start: CaptureStart) throws(FrameRefusal)
        -> Frame
    {
        try world.withLock { world throws(FrameRefusal) in
            let reading = clock()
            if let blocking = world.report.state(at: reading).blocking { throw .blocked(blocking) }
            var leaseHolder: FrameScope?
            if case .held(let lease) = world.lease.state(at: reading) {
                leaseHolder = FrameScope(principal: lease.holder.principal, holderID: lease.holder.holderID)
            }
            do throws(FrameRecordError) {
                return try world.frames.record(
                    capture, for: scope, leaseHolder: leaseHolder, startedIn: start.epoch, now: reading.wall)
            } catch {
                switch error {
                // Every invalidation comes with the state that caused it; the fallback is unreachable.
                case .invalidatedDuringCapture: throw .blocked(world.invalidatedBy ?? .permissionStale)
                case .inconsistentCapture: throw .inconsistentCapture
                }
            }
        }
    }

    private static func droppingState(in active: ActiveStates) -> LeaseDroppingState? {
        active.states.compactMap(\.leaseDropping).min()
    }
}

/// What `status` reads from the owner at one reading.
struct StatusView: Sendable {
    let reading: ClockReading
    let activeStates: ActiveStates
    /// As the latest reduction left them.
    let conditions: Set<Condition>
    let armedUntil: Timestamp?
    let lease: LeaseView?

    var state: DeskhandState { activeStates.current }
}

/// See ``DeskOwner/beginCapture()``.
struct CaptureStart: Sendable {
    let reading: ClockReading
    let state: DeskhandState
    let policy: AppPolicy
    let epoch: FrameStore.Epoch
}

enum FrameRefusal: Error, Hashable, Sendable {
    /// The state is not `ok`, or every frame was invalidated while this one was captured.
    case blocked(BlockingState)
    /// The platform's capture disagrees with itself: `internal_error`.
    case inconsistentCapture
}
