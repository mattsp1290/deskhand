import DeskhandCore
import Testing

private let crew = Principal(certificateSubject: "CN=crew-executor,O=crew")
private let stranger = Principal(certificateSubject: "CN=someone-else,O=crew")
private let mine = HolderID("exec-1")!
private let theirs = HolderID("exec-2")!
private let now = ClockReading(wall: Timestamp(millisecondsSinceEpoch: 1_800_000_000_000), monotonic: .now)

private func at(_ offsetMs: Int64) -> ClockReading { now.advanced(byMilliseconds: offsetMs) }

/// Built through the real argument parser, as the server builds it.
private func request(_ op: LeaseOperation, _ holder: HolderID = mine, ttlMs: Int? = nil) -> LeaseArguments {
    var arguments: JSONObject = ["op": .string(op.rawValue), "holder_id": .string(holder.rawValue)]
    arguments["ttl_ms"] = ttlMs.map { JSONValue($0) }
    return try! LeaseArguments(arguments: arguments)
}

private func acquired(by principal: Principal, _ holder: HolderID, at time: ClockReading, ttlMs: Int = 30_000)
    -> LeaseManager
{
    var manager = LeaseManager()
    let applied = manager.apply(request(.acquire, holder, ttlMs: ttlMs), principal: principal, state: .ok, now: time)
    precondition(applied.result.result.outcome == .acquired)
    return manager
}

extension LeaseManager {
    fileprivate mutating func run(_ op: LeaseOperation, _ holder: HolderID = mine, at time: ClockReading)
        -> LeaseApplication
    {
        apply(request(op, holder), principal: crew, state: .ok, now: time)
    }
}

/// The lease situations of contract 5.1 and 5.3 as seen by the caller (`crew`, `exec-1`) at `now`.
enum Situation: String, CaseIterable, Sendable {
    case noLeaseSinceStart
    case heldByCaller
    case heldByOtherHolder
    case heldBySameHolderIDUnderOtherPrincipal
    case callerLeaseRanOut
    case callerLeaseRanOutAndWasSettled
    case otherHolderLeaseRanOut
    case callerReleased
    case callerLeaseDropped
    case callerLeaseRanOutThenStateDropped
    case callerLeaseRanOutThenOtherAcquiredAndReleased

    var manager: LeaseManager {
        switch self {
        case .noLeaseSinceStart: return LeaseManager()
        case .heldByCaller: return acquired(by: crew, mine, at: at(-1000))
        case .heldByOtherHolder: return acquired(by: crew, theirs, at: at(-1000))
        case .heldBySameHolderIDUnderOtherPrincipal: return acquired(by: stranger, mine, at: at(-1000))
        case .callerLeaseRanOut: return acquired(by: crew, mine, at: at(-30_000))
        case .callerLeaseRanOutAndWasSettled:
            var manager = acquired(by: crew, mine, at: at(-60_000))
            _ = manager.expire(now: at(-30_000))
            return manager
        case .otherHolderLeaseRanOut: return acquired(by: crew, theirs, at: at(-30_000))
        case .callerReleased:
            var manager = acquired(by: crew, mine, at: at(-1000))
            _ = manager.run(.release, at: at(-500))
            return manager
        case .callerLeaseDropped:
            var manager = acquired(by: crew, mine, at: at(-1000))
            _ = manager.drop(because: .disarmed, now: at(-500))
            return manager
        case .callerLeaseRanOutThenStateDropped:
            var manager = acquired(by: crew, mine, at: at(-60_000))
            _ = manager.drop(because: .gated, now: at(-1000))
            return manager
        case .callerLeaseRanOutThenOtherAcquiredAndReleased:
            var manager = acquired(by: crew, mine, at: at(-60_000))
            _ = manager.run(.acquire, theirs, at: at(-2000))
            _ = manager.run(.release, theirs, at: at(-1000))
            return manager
        }
    }

    /// Contract 5.1's table, one entry per operation, then the effect-call check of 5.3.
    var expected: (acquire: LeaseOutcome, renew: LeaseOutcome, release: LeaseOutcome, check: LeaseDenial?) {
        switch self {
        case .heldByCaller: (.renewed, .renewed, .released, nil)
        case .heldByOtherHolder, .heldBySameHolderIDUnderOtherPrincipal:
            (
                .refused(.leaseHeldByOther(expiresInMs: 29_000)), .refused(.leaseHeldByOther(expiresInMs: 29_000)),
                .refused(.leaseHeldByOther(expiresInMs: 29_000)), .heldByOther(expiresInMs: 29_000)
            )
        case .callerLeaseRanOut, .callerLeaseRanOutAndWasSettled, .callerLeaseRanOutThenStateDropped:
            (.acquired, .refused(.leaseExpired), .notHeld, .expired)
        case .noLeaseSinceStart, .otherHolderLeaseRanOut, .callerReleased, .callerLeaseDropped,
            .callerLeaseRanOutThenOtherAcquiredAndReleased:
            (.acquired, .refused(.leaseNotHeld), .notHeld, .notHeld)
        }
    }
}

@Suite struct LeaseManagerTests {
    @Test(arguments: Situation.allCases)
    func operationsFollowTheContractTable(_ situation: Situation) {
        let expected = situation.expected
        for (op, outcome) in [
            (LeaseOperation.acquire, expected.acquire), (.renew, expected.renew), (.release, expected.release),
        ] {
            var manager = situation.manager
            let applied = manager.run(op, at: now)
            #expect(applied.result.result == LeaseResult(operation: op, outcome: outcome), "\(op)")
            let heldAfter = outcome == .acquired || outcome == .renewed
            #expect(applied.result.lease.heldByCaller == heldAfter, "\(op)")
        }
    }

    @Test(arguments: Situation.allCases)
    func effectCheckFollowsHowTheLeaseEnded(_ situation: Situation) {
        let manager = situation.manager
        let denial: LeaseDenial?
        do throws(LeaseDenial) {
            let lease = try manager.check(principal: crew, holderID: mine, now: now)
            #expect(lease.holder == LeaseHolder(principal: crew, holderID: mine))
            denial = nil
        } catch {
            denial = error
        }
        #expect(denial == situation.expected.check)
    }

    @Test(arguments: Situation.allCases)
    func refusalsLeaveTheLeaseUnchanged(_ situation: Situation) {
        for op in LeaseOperation.allCases {
            var manager = situation.manager
            let before = manager.state(at: now)
            let applied = manager.run(op, at: now)
            if case .refused = applied.result.result.outcome {
                #expect(manager.state(at: now) == before, "\(op)")
                #expect(applied.result.lease == .notHeldByCaller)
            }
        }
    }

    @Test(arguments: DeskhandState.allCases)
    func acquireAndRenewAreRefusedOnlyWhileTheLeaseIsDropped(_ state: DeskhandState) {
        let dropping = state.blocking?.leaseDropping
        var fresh = LeaseManager()
        let acquire = fresh.apply(request(.acquire), principal: crew, state: state, now: now).result.result
        #expect(acquire.outcome == (dropping.map { .refused(.state($0)) } ?? .acquired))
        #expect(fresh.deadline == (dropping == nil ? at(30_000).monotonic : nil))

        var held = acquired(by: crew, mine, at: at(-1000))
        let renew = held.apply(request(.renew), principal: crew, state: state, now: now).result.result
        #expect(renew.outcome == (dropping.map { .refused(.state($0)) } ?? .renewed))

        let release = held.apply(request(.release), principal: crew, state: state, now: now)
        #expect(release.result.result.outcome == .released)
        #expect(release.ended?.cause == .released)
        #expect(held.lease == .none)
    }

    @Test(arguments: [nil, 5000, 120_000])
    func acquireAndRenewSetExpiryFromNow(_ ttlMs: Int?) throws {
        let ttl = Int64(ttlMs ?? ContractConstants.defaultLeaseTTLMs)
        var manager = LeaseManager()
        _ = manager.apply(request(.acquire, ttlMs: ttlMs), principal: crew, state: .ok, now: now)
        #expect(manager.deadline == at(ttl).monotonic)

        _ = manager.apply(request(.renew, ttlMs: ttlMs), principal: crew, state: .ok, now: at(3000))
        #expect(manager.deadline == at(3000 + ttl).monotonic)

        _ = manager.apply(request(.acquire, ttlMs: 5000), principal: crew, state: .ok, now: at(4000))
        let lease = try manager.check(principal: crew, holderID: mine, now: at(4000))
        #expect(lease.acquiredAt == now.wall)
        #expect(lease.expiresAt(at: at(4000)) == at(9000).wall)
    }

    @Test func renewalKeepsTheAcquisitionAndReacquiringStartsANewOne() throws {
        var manager = acquired(by: crew, mine, at: now)
        let first = try manager.check(principal: crew, holderID: mine, now: now)
        _ = manager.run(.renew, at: at(1000))
        #expect(try manager.check(principal: crew, holderID: mine, now: at(1000)).serial == first.serial)

        _ = manager.run(.release, at: at(2000))
        _ = manager.run(.acquire, at: at(2000))
        #expect(try manager.check(principal: crew, holderID: mine, now: at(2000)).serial != first.serial)
    }

    @Test func leaseRunsOutAtItsExpiryInstant() {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 5000)
        #expect(manager.deadline == at(5000).monotonic)
        #expect(throws: Never.self) { try manager.check(principal: crew, holderID: mine, now: at(4999)) }
        #expect(manager.expire(now: at(4999)) == nil)
        #expect(throws: LeaseDenial.expired) { try manager.check(principal: crew, holderID: mine, now: at(5000)) }

        let end = manager.expire(now: at(5000))
        #expect(end?.cause == .expired)
        #expect(end?.cause.abortReason == .leaseExpired)
        #expect(end?.lease.holder == LeaseHolder(principal: crew, holderID: mine))
        #expect(manager.lastEnd == end)
        #expect(manager.deadline == nil)
        #expect(manager.expire(now: at(6000)) == nil)
    }

    @Test func aWallClockStepNeitherLengthensNorShortensTheLease() throws {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 10_000)
        let steppedBack = ClockReading(wall: at(-60_000).wall, monotonic: at(9_999).monotonic)
        let lease = try manager.check(principal: crew, holderID: mine, now: steppedBack)
        #expect(lease.remainingMs(at: steppedBack) == 1)
        #expect(lease.expiresAt(at: steppedBack) == steppedBack.wall.adding(milliseconds: 1))
        let stillBack = ClockReading(wall: at(-50_000).wall, monotonic: at(10_000).monotonic)
        #expect(throws: LeaseDenial.expired) { try manager.check(principal: crew, holderID: mine, now: stillBack) }
        #expect(manager.expire(now: stillBack)?.cause == .expired)
    }

    @Test func leaseExpiredHasNoTimeLimitAndEndsWhenAnyoneAcquires() {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 5000)
        let muchLater = at(30 * 86_400_000)
        #expect(throws: LeaseDenial.expired) { try manager.check(principal: crew, holderID: mine, now: muchLater) }

        _ = manager.run(.release, at: muchLater)
        #expect(throws: LeaseDenial.expired) { try manager.check(principal: crew, holderID: mine, now: muchLater) }

        _ = manager.run(.acquire, theirs, at: muchLater)
        _ = manager.run(.release, theirs, at: muchLater)
        #expect(throws: LeaseDenial.notHeld) { try manager.check(principal: crew, holderID: mine, now: muchLater) }
    }

    @Test(arguments: LeaseDroppingState.allCases)
    func droppingEndsALiveLeaseWithTheStateName(_ state: LeaseDroppingState) {
        var manager = acquired(by: crew, mine, at: now)
        let end = manager.drop(because: state, now: at(1000))
        #expect(end?.cause == .dropped(state))
        #expect(end?.cause.abortReason == .blocked(state.blocking))
        #expect(manager.lease == .none)
        #expect(manager.deadline == nil)
        #expect(manager.drop(because: state, now: at(2000)) == nil)
    }

    @Test func droppingAnExpiredLeaseReportsTheExpiryAndKeepsLeaseExpired() {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 5000)
        let end = manager.drop(because: .paused, now: at(5000))
        #expect(end?.cause == .expired)
        #expect(manager.drop(because: .paused, now: at(5001)) == nil)
        #expect(throws: LeaseDenial.expired) { try manager.check(principal: crew, holderID: mine, now: at(6000)) }
    }

    @Test func aLeaseCallReportsTheExpiryItSettles() {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 5000)
        let applied = manager.run(.acquire, at: at(5001))
        #expect(applied.result.result.outcome == .acquired)
        #expect(applied.ended?.cause == .expired)
        #expect(applied.ended?.lease.holder == LeaseHolder(principal: crew, holderID: mine))
        #expect(manager.expire(now: at(5002)) == nil)
    }

    @Test func releaseReportsTheLeaseItEnds() {
        var manager = acquired(by: crew, mine, at: now)
        let applied = manager.run(.release, at: at(1000))
        #expect(applied.ended?.cause == .released)
        #expect(applied.ended?.cause.abortReason == .leaseNotHeld)
        #expect(manager.run(.release, at: at(1001)).ended == nil)
    }

    @Test func thePerEventCheckNamesHowTheAdmittedLeaseEnded() throws {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 5000)
        let admitted = try manager.check(principal: crew, holderID: mine, now: now)
        #expect(manager.endCause(of: admitted, now: at(4999)) == nil)
        #expect(manager.endCause(of: admitted, now: at(5000)) == .expired)

        // Ran out, then another holder acquired before the next per-event check.
        _ = manager.run(.acquire, theirs, at: at(6000))
        #expect(manager.endCause(of: admitted, now: at(6001)) == .expired)

        // Released, then the same holder acquired again: a new serial, so the old effect ends.
        var again = acquired(by: crew, mine, at: now)
        let first = try again.check(principal: crew, holderID: mine, now: now)
        _ = again.run(.release, at: at(100))
        _ = again.run(.acquire, at: at(200))
        #expect(again.endCause(of: first, now: at(300)) == .released)

        var dropped = acquired(by: crew, mine, at: now)
        let underDrop = try dropped.check(principal: crew, holderID: mine, now: now)
        _ = dropped.drop(because: .gated, now: at(100))
        #expect(dropped.endCause(of: underDrop, now: at(200))?.abortReason == .blocked(.gated))
    }

    /// Re-review A, finding 2: leases that begin and end after the admitted one do not relabel how
    /// it ended.
    @Test func laterLeasesDoNotRelabelHowTheAdmittedLeaseEnded() throws {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 5000)
        let admitted = try manager.check(principal: crew, holderID: mine, now: now)
        _ = manager.run(.acquire, theirs, at: at(6000))
        _ = manager.run(.release, theirs, at: at(6100))
        #expect(manager.lastEnd?.cause == .released)
        #expect(manager.endCause(of: admitted, now: at(6200)) == .expired)

        // The admitted lease's end and one release are kept; fill the rest of the retained ends.
        for index in 2..<LeaseManager.retainedEnds {
            _ = manager.run(.acquire, theirs, at: at(7000 + Int64(index)))
            _ = manager.run(.release, theirs, at: at(7000 + Int64(index)))
        }
        #expect(manager.endCause(of: admitted, now: at(8000)) == .expired)
        _ = manager.run(.acquire, theirs, at: at(8000))
        _ = manager.run(.release, theirs, at: at(8000))
        #expect(manager.endCause(of: admitted, now: at(8001)) == .released, "beyond the retained ends")
    }

    /// Re-review B, finding 2: the deadline of the admitted lease moves with a renewal, and is gone
    /// once that lease no longer holds.
    @Test func theAdmittedLeasesDeadlineFollowsRenewals() throws {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 10_000)
        let admitted = try manager.check(principal: crew, holderID: mine, now: now)
        #expect(manager.deadline(of: admitted) == at(10_000).monotonic)
        _ = manager.run(.renew, at: at(4000))
        #expect(manager.deadline(of: admitted) == at(34_000).monotonic)
        #expect(admitted.deadline == at(10_000).monotonic, "the admission snapshot does not move")

        _ = manager.run(.release, at: at(5000))
        #expect(manager.deadline(of: admitted) == nil)
        _ = manager.run(.acquire, at: at(5000))
        #expect(manager.deadline(of: admitted) == nil, "a new acquisition is another lease")
    }

    @Test func leaseSurvivesTokenReplacementBecauseThePrincipalIsTheCertificateSubject() throws {
        let manager = acquired(by: crew, mine, at: now)
        let sameCertificateNewToken = Principal(certificateSubject: crew.certificateSubject)
        let lease = try manager.check(principal: sameCertificateNewToken, holderID: mine, now: at(1000))
        #expect(lease.holder.principal == crew)
        #expect(
            manager.view(for: LeaseHolder(principal: sameCertificateNewToken, holderID: mine), now: at(1000))
                .heldByCaller)
    }

    @Test func aCanonicallyEquivalentSubjectIsAnotherPrincipal() {
        let composed = Principal(certificateSubject: "CN=caf\u{E9}")
        let decomposed = Principal(certificateSubject: "CN=cafe\u{301}")
        #expect(composed != decomposed)
        let manager = acquired(by: composed, mine, at: now)
        #expect(throws: LeaseDenial.heldByOther(expiresInMs: 29_000)) {
            try manager.check(principal: decomposed, holderID: mine, now: at(1000))
        }
    }

    @Test func theViewSaysOnlyWhetherTheNamedHolderHoldsIt() {
        let manager = acquired(by: crew, theirs, at: now, ttlMs: 10_000)
        #expect(
            manager.view(for: LeaseHolder(principal: crew, holderID: theirs), now: at(2500))
                == .heldByCaller(acquiredAt: now.wall, expiresAt: at(10_000).wall, expiresInMs: 7500))
        #expect(manager.view(for: LeaseHolder(principal: crew, holderID: mine), now: at(2500)) == .notHeldByCaller)
        #expect(
            manager.view(for: LeaseHolder(principal: stranger, holderID: theirs), now: at(2500)) == .notHeldByCaller)
        #expect(manager.view(for: LeaseHolder(principal: crew, holderID: theirs), now: at(10_000)) == .notHeldByCaller)
        #expect(LeaseView.notHeldByCaller.jsonValue == ["held_by_caller": false])
    }

    @Test func deniedEffectCallsCarryTheContractCodes() {
        let cases: [(LeaseDenial, ToolErrorCode)] = [
            (.notHeld, .leaseNotHeld), (.heldByOther(expiresInMs: 1234), .leaseHeldByOther), (.expired, .leaseExpired),
        ]
        for (denial, code) in cases {
            let error = ToolError(denial.reason, message: denial.message, state: .ok)
            #expect(error.code == code)
            #expect(!denial.message.contains("status"))
        }
        let heldByOther = ToolError(
            LeaseDenial.heldByOther(expiresInMs: 1234).reason, message: "", state: .ok
        ).jsonValue
        #expect(heldByOther["details"] == ["expires_in_ms": 1234])
    }
}
