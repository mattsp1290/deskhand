/// Per-Mac settings that change how states combine.
public struct StateConfiguration: Hashable, Sendable {
    /// `gated_ends_arming` (contract 10.4): arming ends when `gated` begins.
    public var gatedEndsArming: Bool

    public init(gatedEndsArming: Bool) { self.gatedEndsArming = gatedEndsArming }

    /// The contract's defaults.
    public static let standard = StateConfiguration(gatedEndsArming: true)
}

/// The state deskhand reports, and the arming and signals it carries into the next reduction.
///
/// Two transitions need no new reading: arming runs out at `armed_until`, and the allowance expires
/// at its `expires_at`. A report is therefore read through ``activeStates(at:)`` and
/// ``state(at:)``, which carry it forward by the clock exactly as the next reduction will: a report
/// that was `ok` one millisecond before `armed_until` is not `ok` after it, whoever holds it, and
/// whatever the next reduction reads, it starts from that. The owner still reduces again by
/// ``validUntil(at:)`` so that the transition's effects run within the deadline bound.
/// `status.conditions` is ``conditions`` plus `user_active`, which `status` evaluates when it is
/// called (contract 11.5).
public struct StateReport: Hashable, Sendable {
    public let arming: Arming
    /// Never contains `user_active`.
    public let conditions: Set<Condition>
    let reducedStates: ActiveStates
    let signals: StateSignals
    let configuration: StateConfiguration
    let allowanceLapse: AllowanceLapse?

    init(
        arming: Arming, signals: StateSignals, configuration: StateConfiguration, allowanceLapse: AllowanceLapse?,
        now: ClockReading
    ) {
        var states = Set(arming.blockingStates)
        if !Self.allowanceIsValid(signals.allowance, lapse: allowanceLapse, at: now) { states.insert(.gated) }
        for signal in PlatformSignal.allCases where signals[signal].holds { states.insert(signal.feeds) }
        var conditions: Set<Condition> = []
        if signals.credentialsWarning { conditions.insert(.credentialsWarning) }
        if signals.cleanupPending { conditions.insert(.cleanupPending) }
        if signals.logUnavailable { conditions.insert(.logUnavailable) }
        if signals[.loginWindow].holds { conditions.insert(.loginWindow) }
        self.arming = arming
        self.reducedStates = ActiveStates(states)
        self.conditions = conditions
        self.signals = signals
        self.configuration = configuration
        self.allowanceLapse = allowanceLapse
    }

    /// The states that hold at `now`: those of the reduction carried forward by the clock, so
    /// `disarmed` once arming has run out and `gated` once the allowance has expired, with
    /// `gated_ends_arming` applied. `status.active_states`, and what every admission and per-event
    /// check reads. The next reduction starts from exactly these.
    public func activeStates(at now: ClockReading) -> ActiveStates { elapsed(until: now).report.reducedStates }

    /// `status.state` at `now`.
    public func state(at now: ClockReading) -> DeskhandState { activeStates(at: now).current }

    /// `status.armed_until` at `now`.
    public func armedUntil(at now: ClockReading) -> Timestamp? { elapsed(until: now).report.arming.armedUntil(at: now) }

    /// The instant this report stops describing the Mac without a new reduction: when arming runs
    /// out or the allowance expires, whichever is first. The owner reduces again at this instant at
    /// the latest. `nil` when neither can happen.
    public func validUntil(at now: ClockReading) -> ContinuousClock.Instant? {
        expiries(seenFrom: now).map(\.monotonic).min()
    }

    /// The deadline of an effect executing under `admitted` (contract 13.1): the earliest of the
    /// allowance's expiry, the lease's and the arming's. The lease's is read from `leases`, so a
    /// renewal moves it. Already past when any of the three has ended, including when `admitted` is
    /// no longer the live lease. Recompute it after every `lease` call, every reduction and every
    /// allowance read.
    public func effectDeadline(of admitted: Lease, leases: LeaseManager, at now: ClockReading)
        -> ContinuousClock.Instant
    {
        let arming: ContinuousClock.Instant =
            switch self.arming {
            case .armed(let until): until
            case .disarmed, .paused: now.monotonic
            }
        let allowance: ContinuousClock.Instant =
            switch signals.allowance {
            case .valid(let expiresAt): Self.lapseInstant(of: expiresAt, lapse: allowanceLapse, seenFrom: now)
            case .invalid, .missing: now.monotonic
            }
        return min(leases.deadline(of: admitted) ?? now.monotonic, arming, allowance)
    }

    /// The report before anything has been read: `disarmed`, as every start is, and every state that
    /// a missing reading makes hold. Seed the first ``StateReducer/reduce(previous:signals:command:configuration:now:)``
    /// with it.
    public static let startup = StateReport(
        arming: .disarmed, signals: .unread, configuration: .standard, allowanceLapse: nil,
        now: ClockReading(wall: Timestamp(millisecondsSinceEpoch: 0), monotonic: ContinuousClock.now))

    func elapsed(until now: ClockReading) -> (report: StateReport, effects: [TransitionEffect]) {
        var report = self
        var effects: [TransitionEffect] = []
        for instant in expiries(seenFrom: now) where instant.monotonic <= now.monotonic {
            let step = StateReducer.step(
                from: report, signals: signals, command: nil, configuration: configuration, now: instant)
            report = step.report
            effects += step.effects
        }
        return (report, effects)
    }

    private func expiries(seenFrom now: ClockReading) -> [ClockReading] {
        var instants: [ClockReading] = []
        if case .armed(let until) = arming {
            let millisecondsAgo = (until.duration(to: now.monotonic) / .milliseconds(1)).rounded(.up)
            instants.append(
                ClockReading(wall: now.wall.adding(milliseconds: -Int64(millisecondsAgo)), monotonic: until))
        }
        if case .valid(let expiresAt) = signals.allowance, !reducedStates.states.contains(.gated) {
            let lapse = Self.lapseInstant(of: expiresAt, lapse: allowanceLapse, seenFrom: now)
            instants.append(ClockReading(wall: expiresAt, monotonic: lapse))
        }
        instants.sort { $0.monotonic < $1.monotonic }
        if instants.count == 2, instants[0].monotonic == instants[1].monotonic { instants.removeLast() }
        return instants
    }

    /// Contract 14.3 at `now`, and the lapse placed on the monotonic clock has not passed either.
    static func allowanceIsValid(_ allowance: AllowanceVerdict, lapse: AllowanceLapse?, at now: ClockReading) -> Bool {
        guard case .valid(let expiresAt) = allowance, now.wall < expiresAt else { return false }
        return now.monotonic < lapseInstant(of: expiresAt, lapse: lapse, seenFrom: now)
    }

    private static func lapseInstant(of expiresAt: Timestamp, lapse: AllowanceLapse?, seenFrom now: ClockReading)
        -> ContinuousClock.Instant
    {
        let seen = now.instant(atWallTime: expiresAt)
        guard let lapse, lapse.expiresAt == expiresAt else { return seen }
        return min(seen, lapse.instant)
    }
}

/// The earliest monotonic instant at which any reduction placed one allowance's `expires_at`.
///
/// Contract 14.3 never extends `expires_at`, and readers act on a lapse before the owner reduces
/// it. A wall clock set back across `expires_at` must not make an allowance valid again once it
/// lapsed, nor leave a lapse that readers saw as `gated` without its effects. So the allowance
/// lapses at whichever comes first: the wall clock reaching `expires_at`, or this instant.
struct AllowanceLapse: Hashable, Sendable {
    let expiresAt: Timestamp
    let instant: ContinuousClock.Instant

    /// The placement a reduction at `now` keeps. One for the same `expires_at` carries over, also
    /// through readings in which the allowance was missing or invalid.
    static func carried(from previous: AllowanceLapse?, allowance: AllowanceVerdict, now: ClockReading)
        -> AllowanceLapse?
    {
        guard case .valid(let expiresAt) = allowance else { return previous }
        let seen = now.instant(atWallTime: expiresAt)
        guard let previous, previous.expiresAt == expiresAt else {
            return AllowanceLapse(expiresAt: expiresAt, instant: seen)
        }
        return AllowanceLapse(expiresAt: expiresAt, instant: min(seen, previous.instant))
    }
}

/// Work a change of state requires. Effects are data; the caller carries them out in list order.
public enum TransitionEffect: Hashable, Sendable {
    /// Abort the executing effect, refuse every `displays` and `screenshot` call that has not
    /// answered, and discard a screenshot captured but not returned, all with this state's name
    /// (contract 10.3 step 1).
    case cancelInFlight(BlockingState)
    /// Release what the aborted effect held, if cleanup is authorized (contract 10.3 step 2, 12.8).
    case releaseHeldInput
    /// Invalidate every frame of every holder (contract 10.3 step 3).
    case invalidateFrames
    /// `gated`, `paused` or `disarmed` began (contract 10.4) at the reading `at`: pass both to
    /// ``LeaseManager/drop(because:now:)``, before settling expiries at the reduction's own reading.
    /// It is the highest of those that began at one instant. A reduction that settles several
    /// lapses carries one per lapse, each with its own instant, so a lease that was live when a
    /// lapse settled late began is dropped, not expired; the later ones find no lease.
    case dropLease(LeaseDroppingState, at: ClockReading)
}

/// One owner keeps the latest ``StateReport``, feeds it back as `previous` and serializes the
/// reductions. However late a reduction runs, it first reduces every transition the clock made
/// since `previous` at the instant it happened, so no transition and none of its effects is
/// skipped.
public enum StateReducer {
    /// The report for `signals` at `now`, after `command` if a person issued one, and the effects of
    /// the change from `previous`. Pure: the same arguments always give the same result.
    ///
    /// The effects are those of every transition the clock made between `previous` and `now`
    /// (arming running out, the allowance expiring), in the order they happened, followed by those
    /// of this reduction. They equal the effects of reducing at each of those instants with the
    /// signals of `previous`, and then at `now`. A lapse renewed before this reduction still runs
    /// its effects, and still ends arming when `gated` began and the configuration says so.
    ///
    /// An arming command that ``ArmingRefusal/of(_:activity:now:)`` refuses leaves arming as it was.
    /// When `gated` begins and the configuration says so, arming ends.
    public static func reduce(
        previous: StateReport, signals: StateSignals, command: ArmingCommand? = nil,
        configuration: StateConfiguration = .standard, now: ClockReading
    ) -> (report: StateReport, effects: [TransitionEffect]) {
        let elapsed = previous.elapsed(until: now)
        let next = step(
            from: elapsed.report, signals: signals, command: command, configuration: configuration, now: now)
        return (next.report, elapsed.effects + next.effects)
    }

    static func step(
        from previous: StateReport, signals: StateSignals, command: ArmingCommand?, configuration: StateConfiguration,
        now: ClockReading
    ) -> (report: StateReport, effects: [TransitionEffect]) {
        let refusal = ArmingRefusal.of(command, activity: signals.ownInput, now: now)
        var arming = previous.arming.applying(command, refusal: refusal, now: now)
        let lapse = AllowanceLapse.carried(from: previous.allowanceLapse, allowance: signals.allowance, now: now)
        let gatedBegins =
            !StateReport.allowanceIsValid(signals.allowance, lapse: lapse, at: now)
            && !previous.reducedStates.states.contains(.gated)
        if gatedBegins, configuration.gatedEndsArming, case .armed = arming { arming = .disarmed }
        let report = StateReport(
            arming: arming, signals: signals, configuration: configuration, allowanceLapse: lapse, now: now)
        return (report, effects(from: previous.reducedStates, to: report.reducedStates, at: now))
    }

    private static func effects(from previous: ActiveStates, to next: ActiveStates, at now: ClockReading)
        -> [TransitionEffect]
    {
        var effects: [TransitionEffect] = []
        if previous.current == .ok, let state = next.current.blocking {
            effects += [.cancelInFlight(state), .releaseHeldInput, .invalidateFrames]
        }
        if let dropping = next.states.subtracting(previous.states).compactMap(\.leaseDropping).min() {
            effects.append(.dropLease(dropping, at: now))
        }
        return effects
    }
}
