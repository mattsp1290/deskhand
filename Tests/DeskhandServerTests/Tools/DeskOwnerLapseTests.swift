import DeskhandCore
import Synchronization
import Testing

@testable import DeskhandServer

/// Both clocks set independently, so a test can step the wall clock without the monotonic one.
private final class SteppingClock: Sendable {
    private let offsets = Mutex<(wall: Int64, monotonic: Int64)>((0, 0))

    var reading: ClockReading {
        let (wall, monotonic) = offsets.withLock { $0 }
        return ClockReading(wall: at(wall).wall, monotonic: at(monotonic).monotonic)
    }

    func set(wall: Int64, monotonic: Int64) { offsets.withLock { $0 = (wall, monotonic) } }

    func set(_ offsetMs: Int64) { set(wall: offsetMs, monotonic: offsetMs) }
}

private func at(_ offsetMs: Int64) -> ClockReading { ToolFixture.t0.advanced(byMilliseconds: offsetMs) }

@Suite(.timeLimit(.minutes(1))) struct DeskOwnerLapseTests {
    private let clock = SteppingClock()
    private let owner: DeskOwner
    private let holder = LeaseHolder(principal: ToolFixture.principal, holderID: ToolFixture.holder)

    init() {
        let clock = clock
        owner = DeskOwner(policy: ToolFixture.policy, displays: FakeDisplays(), clock: { clock.reading })
    }

    private static func signals(allowanceUntil offsetMs: Int64) -> StateSignals {
        var signals = ToolFixture.signals()
        signals.allowance = .valid(expiresAt: at(offsetMs).wall)
        return signals
    }

    private static func gated(at lapse: ClockReading) -> [TransitionEffect] {
        [.cancelInFlight(.gated), .releaseHeldInput, .invalidateFrames, .dropLease(.gated, at: lapse)]
    }

    /// Armed for an hour under an allowance until 10 s, with a lease of `ttlMs` taken at 0.
    private func armedWithLease(ttlMs: Int) throws -> Lease {
        owner.reduce(signals: Self.signals(allowanceUntil: 10_000), command: .arm(for: .seconds(3600)))
        _ = owner.applyLease(
            LeaseArguments(holderID: ToolFixture.holder, command: .acquire(ttlMs: ttlMs)),
            principal: ToolFixture.principal)
        let snapshot = owner.snapshot()
        return try snapshot.lease.check(
            principal: ToolFixture.principal, holderID: ToolFixture.holder, now: snapshot.reading)
    }

    @Test func aLapseStatusSawSurvivesTheWallClockSteppingBackAcrossIt() throws {
        let admitted = try armedWithLease(ttlMs: 60_000)
        let epoch = owner.beginRead().epoch

        clock.set(10_500)
        #expect(owner.statusView(for: holder).state == .gated)
        #expect(owner.beginRead().epoch != epoch)
        #expect(owner.snapshot().lease.endCause(of: admitted, now: at(10_500)) == .dropped(.gated))

        clock.set(wall: 9000, monotonic: 11_000)
        let back = owner.reduce(signals: Self.signals(allowanceUntil: 10_000))
        #expect(back.effects == Self.gated(at: at(10_000)))
        #expect(back.leaseEnds.map(\.cause) == [.dropped(.gated)])
        #expect(back.report.state(at: clock.reading) == .disarmed)
        #expect(back.report.armedUntil(at: clock.reading) == nil)

        let again = owner.reduce(signals: Self.signals(allowanceUntil: 10_000))
        #expect(again.effects.isEmpty)
        #expect(again.leaseEnds.isEmpty)
        #expect(owner.statusView(for: holder).state == .disarmed)
    }

    @Test func aLapseTheExecutorSawSurvivesAWallClockSetForwardAndBack() throws {
        let admitted = try armedWithLease(ttlMs: 60_000)

        clock.set(wall: 10_500, monotonic: 5000)
        let seen = owner.snapshot()
        #expect(seen.state == .gated)
        #expect(seen.lease.endCause(of: admitted, now: seen.reading) == .dropped(.gated))

        clock.set(5100)
        let lapse = ClockReading(wall: at(10_000).wall, monotonic: at(4500).monotonic)
        let back = owner.reduce(signals: Self.signals(allowanceUntil: 10_000))
        #expect(back.effects == Self.gated(at: lapse))
        #expect(back.leaseEnds.map(\.cause) == [.dropped(.gated)])
        #expect(back.report.state(at: clock.reading) == .disarmed)

        let again = owner.reduce(signals: Self.signals(allowanceUntil: 10_000))
        #expect(again.effects.isEmpty)
        #expect(owner.snapshot().state == .disarmed)
    }

    @Test func aLateReductionDropsALeaseThatOutlivedTheLapse() throws {
        let admitted = try armedWithLease(ttlMs: 12_000)
        clock.set(13_000)
        let late = owner.reduce(signals: Self.signals(allowanceUntil: 120_000))
        #expect(late.effects == Self.gated(at: at(10_000)))
        #expect(late.leaseEnds.map(\.cause) == [.dropped(.gated)])
        #expect(owner.snapshot().lease.endCause(of: admitted, now: at(13_000)) == .dropped(.gated))
    }

    @Test func aLeaseCallAfterAnUnreducedLapseDropsALeaseThatOutlivedIt() throws {
        _ = try armedWithLease(ttlMs: 12_000)
        clock.set(13_000)
        let renewal = owner.applyLease(
            LeaseArguments(holderID: ToolFixture.holder, command: .renew(ttlMs: 12_000)),
            principal: ToolFixture.principal)
        #expect(renewal.result.result.outcome == .refused(.state(.gated)))
        #expect(renewal.ended.map(\.cause) == [.dropped(.gated)])

        let next = owner.reduce(signals: Self.signals(allowanceUntil: 120_000))
        #expect(next.effects == Self.gated(at: at(10_000)))
        #expect(next.leaseEnds.isEmpty)
    }

    @Test func anEndAReaderCommittedReachesTheNextReductionOnceAfterALeaseCall() throws {
        _ = try armedWithLease(ttlMs: 60_000)
        clock.set(10_500)
        #expect(owner.statusView(for: holder).state == .gated)
        let renewal = owner.applyLease(
            LeaseArguments(holderID: ToolFixture.holder, command: .renew(ttlMs: 12_000)),
            principal: ToolFixture.principal)
        #expect(renewal.ended.isEmpty)

        let next = owner.reduce(signals: Self.signals(allowanceUntil: 10_000))
        #expect(next.effects == Self.gated(at: at(10_000)))
        #expect(next.leaseEnds.map(\.cause) == [.dropped(.gated)])
        #expect(owner.reduce(signals: Self.signals(allowanceUntil: 10_000)).leaseEnds.isEmpty)
    }

    @Test func anArmingExpiryAReaderCommittedDropsTheLeaseAtItsInstant() throws {
        owner.reduce(signals: Self.signals(allowanceUntil: 120_000), command: .arm(for: .seconds(5)))
        _ = owner.applyLease(
            LeaseArguments(holderID: ToolFixture.holder, command: .acquire(ttlMs: 60_000)),
            principal: ToolFixture.principal)
        clock.set(6000)
        #expect(owner.snapshot().state == .disarmed)

        let next = owner.reduce(signals: Self.signals(allowanceUntil: 120_000))
        #expect(next.effects.last == .dropLease(.disarmed, at: at(5000)))
        #expect(next.leaseEnds.map(\.cause) == [.dropped(.disarmed)])
    }

    @Test func aReadCheckRefusesALapseOnlyItSaw() throws {
        _ = try armedWithLease(ttlMs: 60_000)
        let start = owner.beginRead()
        clock.set(wall: 10_500, monotonic: 5000)
        #expect(throws: FrameRefusal.blocked(.gated)) { try owner.checkRead(since: start) }

        clock.set(5100)
        #expect(throws: FrameRefusal.blocked(.gated)) { try owner.checkRead(since: start) }
    }

    @Test func aForwardStepAcrossTheLapseKeepsALeaseThatHadRunOutExpired() throws {
        let admitted = try armedWithLease(ttlMs: 7000)
        clock.set(7500)
        #expect(owner.snapshot().lease.endCause(of: admitted, now: at(7500)) == .expired)

        clock.set(wall: 20_000, monotonic: 8000)
        let seen = owner.snapshot()
        #expect(seen.state == .gated)
        #expect(seen.lease.endCause(of: admitted, now: seen.reading) == .expired)
        #expect(throws: LeaseDenial.expired) {
            try seen.lease.check(
                principal: ToolFixture.principal, holderID: ToolFixture.holder, now: seen.reading)
        }
    }

    @Test func theExecutorSeesALeaseThatOutlivedAnUnreducedLapseAsDropped() throws {
        let admitted = try armedWithLease(ttlMs: 12_000)
        clock.set(13_000)
        let snapshot = owner.snapshot()
        #expect(snapshot.state == .gated)
        #expect(snapshot.lease.endCause(of: admitted, now: snapshot.reading) == .dropped(.gated))
        #expect(throws: LeaseDenial.notHeld) {
            try snapshot.lease.check(
                principal: ToolFixture.principal, holderID: ToolFixture.holder, now: snapshot.reading)
        }
    }
}
