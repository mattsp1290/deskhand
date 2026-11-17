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
/// can see one without the others. The platform's signals are read outside that lock.
public final class DeskOwner: StateSource, FrameSource {
    private struct World {
        var report: StateReport
        var lease = LeaseManager()
        var frames: FrameStore
        var policy: AppPolicy
        var invalidatedBy: BlockingState?
        /// Committed by a reader, not yet returned by a reduction for delivery to the executor.
        var settledEffects: [TransitionEffect] = []
        var settledEnds: [LeaseEnd] = []
        /// The latest reading anything read or reduced the world at. Readings are taken under the
        /// lock, so they never go back.
        var lastReading: ClockReading?

        /// Commits every transition the clock made by `reading` before anything reads the report
        /// there. Readers act on those transitions (a refusal, an abort, `status`), and a wall clock
        /// stepped back before the next reduction would otherwise make the allowance valid again
        /// and lose them with their effects. The next reduction returns them.
        mutating func settle(at reading: ClockReading) {
            defer { lastReading = reading }
            let elapsed = report.elapsed(until: reading)
            guard elapsed.report != report else { return }
            report = elapsed.report
            settledEffects += elapsed.effects
            settledEnds += carryOut(elapsed.effects)
        }

        /// Invalidates frames and drops the lease as `effects` require, and returns the leases
        /// that ended.
        mutating func carryOut(_ effects: [TransitionEffect]) -> [LeaseEnd] {
            var ends: [LeaseEnd] = []
            for effect in effects {
                switch effect {
                case .cancelInFlight(let state): invalidatedBy = state
                case .invalidateFrames: frames.invalidateAll()
                case .dropLease(let state, let lapse):
                    // A wall clock stepped forward across `expires_at` can place the lapse before a
                    // reading that saw the allowance valid. It began no earlier than that reading, so
                    // a lease that had run out by then stays expired (contract 5.3, 10.4).
                    let began = lastReading.map { lapse.monotonic < $0.monotonic ? $0 : lapse } ?? lapse
                    if let end = lease.drop(because: state, now: began) { ends.append(end) }
                case .releaseHeldInput: break
                }
            }
            return ends
        }
    }

    /// The Mac's displays: their generation is part of every frame check.
    public let displays: any DisplayProvider
    public let stateConfiguration: StateConfiguration
    private let clock: @Sendable () -> ClockReading
    private let world: Mutex<World>

    private let reducing = Mutex(())

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

    public func snapshot() -> DeskSnapshot {
        world.withLock { world in
            let reading = clock()
            world.settle(at: reading)
            return DeskSnapshot(reading: reading, report: world.report, lease: world.lease, policy: world.policy)
        }
    }

    public func check(_ id: FrameID, in scope: FrameScope, for use: FrameUse, now: Timestamp) async -> FrameCheck {
        let generation = displays.generation
        return world.withLock { world in
            world.settle(at: clock())
            return world.frames.check(id, in: scope, for: use, displayConfigGeneration: generation, now: now)
        }
    }

    /// What one reduction changed, and what its caller still has to carry out against the executor.
    public struct Reduction: Sendable {
        public let report: StateReport
        /// In order (``TransitionEffect``): first those a reader committed since the last reduction,
        /// when it read the report after the clock had made a transition, then this reduction's.
        /// ``TransitionEffect/invalidateFrames`` and ``TransitionEffect/dropLease(_:at:)`` are
        /// already applied here.
        public let effects: [TransitionEffect]
        /// Every live lease that ended since the last reduction, by running out or by a state that
        /// drops it: first those a reader's commit ended (less any a `lease` call already handed
        /// out), then this reduction's.
        public let leaseEnds: [LeaseEnd]
        public let reading: ClockReading

        /// What stops the executing effect, in order. The state owner passes each to
        /// ``InputExecutor/interrupt(_:)`` as soon as ``DeskOwner/reduce(signals:command:)``
        /// returns, before it awaits anything else. The watchdog also passes what the snapshot
        /// shows when it next looks, which repeats a cause the executor already keeps. A state
        /// that has ended by then leaves no trace in the snapshot, so only this delivery aborts
        /// the effect it interrupted (contract 10.3).
        public var interruptions: [Interruption] {
            var found: [Interruption] = []
            for case .cancelInFlight(let state) in effects { found.append(.state(state)) }
            return found + leaseEnds.map(Interruption.leaseEnded)
        }

        /// The releases owed may be posted now. The state owner need not post them: the
        /// watchdog's executor loop calls ``InputExecutor/retryCleanup(now:)`` after every
        /// reduction.
        public var releasesHeldInput: Bool { effects.contains(.releaseHeldInput) }
    }

    /// Reduces `signals` (and a person's arming `command`) from the current report at the current
    /// reading, settles a lease that has run out, drops the lease and invalidates every frame as
    /// the effects require, all under one lock. The app's state owner calls it from
    /// ``WatchdogStateOwner/reduceNow(allowanceChanged:)``, and on a signal change followed by
    /// ``Watchdog/refreshState()``. Either way it then passes ``Reduction/interruptions`` to
    /// ``InputExecutor/interrupt(_:)``, in order, before it awaits anything else: one hop on the
    /// executor, and only when the reduction stops something. Without it a blocking state that
    /// ends again before the watchdog looks is lost. The delivery is lossless while each
    /// reduction's interruptions reach the executor before the next reduction; an owner that
    /// reduces on several tasks at once leaves a window of that one hop.
    ///
    /// Reductions apply one at a time, in the order their signals were read: a reduction that read
    /// the signals before a newer one cannot apply after it and reopen a state the newer one
    /// closed. `signals` is read outside the lock that ``snapshot()`` takes, so a slow read holds
    /// up the next reduction, never the executor. It must not reduce on this owner.
    @discardableResult
    public func reduce(signals: @autoclosure () -> StateSignals, command: ArmingCommand? = nil) -> Reduction {
        reducing.withLock { _ in apply(signals(), command: command) }
    }

    private func apply(_ signals: StateSignals, command: ArmingCommand?) -> Reduction {
        world.withLock { world in
            let reading = clock()
            let (report, effects) = StateReducer.reduce(
                previous: world.report, signals: signals, command: command, configuration: stateConfiguration,
                now: reading)
            world.report = report
            var ends = world.settledEnds + world.carryOut(effects)
            world.lastReading = reading
            if let end = world.lease.expire(now: reading) { ends.append(end) }
            let allEffects = world.settledEffects + effects
            world.settledEffects = []
            world.settledEnds = []
            return Reduction(report: report, effects: allEffects, leaseEnds: ends, reading: reading)
        }
    }

    /// Replaces the app policy, for a configuration reload. The next check of every call uses it.
    public func updatePolicy(_ policy: AppPolicy) { world.withLock { $0.policy = policy } }

    func statusView(for holder: LeaseHolder?) -> StatusView {
        world.withLock { world in
            let reading = clock()
            world.settle(at: reading)
            let active = world.report.activeStates(at: reading)
            let lease: LeaseView? = holder.map { holder in
                guard Self.droppingState(in: active) == nil else { return .notHeldByCaller }
                return world.lease.view(for: holder, now: reading)
            }
            return StatusView(
                reading: reading, activeStates: active, conditions: world.report.conditions,
                armedUntil: world.report.armedUntil(at: reading), lease: lease)
        }
    }

    func applyLease(_ arguments: LeaseArguments, principal: Principal) -> (result: LeaseToolResult, ended: [LeaseEnd]) {
        world.withLock { world in
            let reading = clock()
            // Ends an earlier reader committed stay queued for the next reduction.
            let queuedBefore = world.settledEnds.count
            world.settle(at: reading)
            var ended = Array(world.settledEnds[queuedBefore...])
            // This call hands them to the executor, so the next reduction must not again.
            world.settledEnds.removeSubrange(queuedBefore...)
            let state = world.report.state(at: reading)
            let application = world.lease.apply(arguments, principal: principal, state: state, now: reading)
            if let end = application.ended { ended.append(end) }
            return (application.result, ended)
        }
    }

    func beginRead() -> ReadStart {
        world.withLock { world in
            let reading = clock()
            world.settle(at: reading)
            return ReadStart(
                reading: reading, state: world.report.state(at: reading), policy: world.policy,
                epoch: world.frames.epoch)
        }
    }

    func checkRead(since start: ReadStart) throws(FrameRefusal) {
        try world.withLock { world throws(FrameRefusal) in
            let reading = clock()
            world.settle(at: reading)
            try Self.checkRead(since: start, in: world, at: reading)
        }
    }

    private static func checkRead(since start: ReadStart, in world: World, at reading: ClockReading)
        throws(FrameRefusal)
    {
        if let blocking = world.report.state(at: reading).blocking { throw .blocked(blocking) }
        if world.frames.epoch != start.epoch { throw .blocked(world.invalidatedBy ?? .permissionStale) }
        if Task.isCancelled { throw .cancelled }
    }

    func record(_ capture: FrameCapture, for scope: FrameScope, startedIn start: ReadStart) throws(FrameRefusal)
        -> Frame
    {
        try world.withLock { world throws(FrameRefusal) in
            let reading = clock()
            world.settle(at: reading)
            try Self.checkRead(since: start, in: world, at: reading)
            var leaseHolder: FrameScope?
            if case .held(let lease) = world.lease.state(at: reading) {
                leaseHolder = FrameScope(principal: lease.holder.principal, holderID: lease.holder.holderID)
            }
            do throws(FrameRecordError) {
                return try world.frames.record(
                    capture, for: scope, leaseHolder: leaseHolder, startedIn: start.epoch, now: reading.wall)
            } catch {
                switch error {
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

struct StatusView: Sendable {
    let reading: ClockReading
    let activeStates: ActiveStates
    let conditions: Set<Condition>
    let armedUntil: Timestamp?
    let lease: LeaseView?

    var state: DeskhandState { activeStates.current }
}

struct ReadStart: Sendable {
    let reading: ClockReading
    let state: DeskhandState
    let policy: AppPolicy
    let epoch: FrameStore.Epoch
}

enum FrameRefusal: Error, Hashable, Sendable {
    case blocked(BlockingState)
    case inconsistentCapture
    case cancelled
}
