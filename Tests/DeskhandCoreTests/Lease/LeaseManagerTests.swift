import DeskhandCore
import Testing

private let crew = Principal(certificateSubject: "CN=crew-executor,O=crew")
private let stranger = Principal(certificateSubject: "CN=someone-else,O=crew")
private let mine = HolderID("exec-1")!
private let theirs = HolderID("exec-2")!
private let now = Timestamp(millisecondsSinceEpoch: 1_800_000_000_000)

private func at(_ offsetMs: Int64) -> Timestamp { now.adding(milliseconds: offsetMs) }

/// Built through the real argument parser, as the server builds it.
private func request(_ op: LeaseOperation, _ holder: HolderID = mine, ttlMs: Int? = nil) -> LeaseRequest {
    var lease: JSONObject = ["op": .string(op.rawValue), "holder_id": .string(holder.rawValue)]
    lease["ttl_ms"] = ttlMs.map { JSONValue($0) }
    return try! StatusArguments(arguments: ["lease": .object(lease)]).lease!
}

private func acquired(by principal: Principal, _ holder: HolderID, at time: Timestamp, ttlMs: Int = 30_000)
    -> LeaseManager
{
    var manager = LeaseManager()
    let result = manager.apply(request(.acquire, holder, ttlMs: ttlMs), principal: principal, state: .ok, now: time)
    precondition(result.outcome == .acquired)
    return manager
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
            _ = manager.apply(request(.release), principal: crew, state: .ok, now: at(-500))
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
            _ = manager.apply(request(.acquire, theirs), principal: crew, state: .ok, now: at(-2000))
            _ = manager.apply(request(.release, theirs), principal: crew, state: .ok, now: at(-1000))
            return manager
        }
    }

    /// Contract 5.1's table, one entry per operation, then the effect-call check of 5.3.
    var expected: (acquire: LeaseOutcome, renew: LeaseOutcome, release: LeaseOutcome, check: LeaseDenial?) {
        switch self {
        case .heldByCaller: (.renewed, .renewed, .released, nil)
        case .heldByOtherHolder, .heldBySameHolderIDUnderOtherPrincipal:
            (
                .refused(.leaseHeldByOther), .refused(.leaseHeldByOther), .refused(.leaseHeldByOther),
                .heldByOther(expiresInMs: 29_000)
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
            let result = manager.apply(request(op), principal: crew, state: .ok, now: now)
            #expect(result == LeaseResult(operation: op, outcome: outcome), "\(op)")
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
            let result = manager.apply(request(op), principal: crew, state: .ok, now: now)
            if case .refused = result.outcome { #expect(manager.state(at: now) == before, "\(op)") }
        }
    }

    @Test(arguments: DeskhandState.allCases)
    func acquireAndRenewAreRefusedOnlyWhileTheLeaseIsDropped(_ state: DeskhandState) {
        let dropping = state.blocking?.dropsLease == true
        var fresh = LeaseManager()
        let acquire = fresh.apply(request(.acquire), principal: crew, state: state, now: now)
        #expect(acquire.outcome == (dropping ? .refused(LeaseRefusal(rawValue: state.rawValue)!) : .acquired))
        #expect(fresh.deadline == (dropping ? nil : at(30_000)))

        var held = acquired(by: crew, mine, at: at(-1000))
        let renew = held.apply(request(.renew), principal: crew, state: state, now: now)
        #expect(renew.outcome == (dropping ? .refused(LeaseRefusal(rawValue: state.rawValue)!) : .renewed))

        let release = held.apply(request(.release), principal: crew, state: state, now: now)
        #expect(release.outcome == .released)
        #expect(held.lease == .none)
    }

    @Test(arguments: [nil, 5000, 120_000])
    func acquireAndRenewSetExpiryFromNow(_ ttlMs: Int?) throws {
        let ttl = Int64(ttlMs ?? ContractConstants.defaultLeaseTTLMs)
        var manager = LeaseManager()
        _ = manager.apply(request(.acquire, ttlMs: ttlMs), principal: crew, state: .ok, now: now)
        #expect(manager.deadline == at(ttl))

        _ = manager.apply(request(.renew, ttlMs: ttlMs), principal: crew, state: .ok, now: at(3000))
        #expect(manager.deadline == at(3000 + ttl))

        _ = manager.apply(request(.acquire, ttlMs: 5000), principal: crew, state: .ok, now: at(4000))
        let lease = try manager.check(principal: crew, holderID: mine, now: at(4000))
        #expect(lease.acquiredAt == now)
        #expect(lease.expiresAt == at(9000))
    }

    @Test func renewalKeepsTheAcquisitionAndReacquiringStartsANewOne() throws {
        var manager = acquired(by: crew, mine, at: now)
        let first = try manager.check(principal: crew, holderID: mine, now: now)
        _ = manager.apply(request(.renew), principal: crew, state: .ok, now: at(1000))
        #expect(try manager.check(principal: crew, holderID: mine, now: at(1000)).serial == first.serial)

        _ = manager.apply(request(.release), principal: crew, state: .ok, now: at(2000))
        _ = manager.apply(request(.acquire), principal: crew, state: .ok, now: at(2000))
        #expect(try manager.check(principal: crew, holderID: mine, now: at(2000)).serial != first.serial)
    }

    @Test func leaseRunsOutAtItsExpiryInstant() {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 5000)
        #expect(manager.deadline == at(5000))
        #expect(throws: Never.self) { try manager.check(principal: crew, holderID: mine, now: at(4999)) }
        #expect(manager.expire(now: at(4999)) == nil)
        #expect(throws: LeaseDenial.expired) { try manager.check(principal: crew, holderID: mine, now: at(5000)) }

        let end = manager.expire(now: at(5000))
        #expect(end?.cause == .expired)
        #expect(end?.cause.abortReason == .leaseExpired)
        #expect(end?.lease.holder == LeaseHolder(principal: crew, holderID: mine))
        #expect(manager.deadline == nil)
        #expect(manager.expire(now: at(6000)) == nil)
    }

    @Test func leaseExpiredHasNoTimeLimitAndEndsWhenAnyoneAcquires() {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 5000)
        let muchLater = at(30 * 86_400_000)
        #expect(throws: LeaseDenial.expired) { try manager.check(principal: crew, holderID: mine, now: muchLater) }

        _ = manager.apply(request(.release), principal: crew, state: .ok, now: muchLater)
        #expect(throws: LeaseDenial.expired) { try manager.check(principal: crew, holderID: mine, now: muchLater) }

        _ = manager.apply(request(.acquire, theirs), principal: crew, state: .ok, now: muchLater)
        _ = manager.apply(request(.release, theirs), principal: crew, state: .ok, now: muchLater)
        #expect(throws: LeaseDenial.notHeld) { try manager.check(principal: crew, holderID: mine, now: muchLater) }
    }

    @Test(arguments: BlockingState.allCases.filter(\.dropsLease))
    func droppingEndsALiveLeaseWithTheStateName(_ state: BlockingState) {
        var manager = acquired(by: crew, mine, at: now)
        let end = manager.drop(because: state, now: at(1000))
        #expect(end?.cause == .dropped(state))
        #expect(end?.cause.abortReason == .blocked(state))
        #expect(manager.lease == .none)
        #expect(manager.deadline == nil)
        #expect(manager.drop(because: state, now: at(2000)) == nil)
    }

    @Test func droppingAnExpiredLeaseKeepsLeaseExpired() {
        var manager = acquired(by: crew, mine, at: now, ttlMs: 5000)
        #expect(manager.drop(because: .paused, now: at(5000)) == nil)
        #expect(throws: LeaseDenial.expired) { try manager.check(principal: crew, holderID: mine, now: at(6000)) }
    }

    @Test func releaseEndsWithLeaseNotHeld() {
        #expect(LeaseEndCause.released.abortReason == .leaseNotHeld)
    }

    @Test func leaseSurvivesTokenReplacementBecauseThePrincipalIsTheCertificateSubject() throws {
        let manager = acquired(by: crew, mine, at: now)
        let sameCertificateNewToken = Principal(certificateSubject: crew.certificateSubject)
        let lease = try manager.check(principal: sameCertificateNewToken, holderID: mine, now: at(1000))
        #expect(lease.holder.principal == crew)
        #expect(manager.view(for: sameCertificateNewToken, now: at(1000))?.holderID == mine)
    }

    @Test func viewShowsTheHolderOnlyToItsPrincipal() {
        let manager = acquired(by: crew, theirs, at: now, ttlMs: 10_000)
        let expected = LeaseView(holderID: theirs, acquiredAt: now, expiresAt: at(10_000), expiresInMs: 7500)
        #expect(manager.view(for: crew, now: at(2500)) == expected)

        var hidden = expected
        hidden.holderID = nil
        #expect(manager.view(for: stranger, now: at(2500)) == hidden)

        #expect(manager.view(for: crew, now: at(10_000)) == nil)
        #expect(LeaseManager().view(for: crew, now: now) == nil)
    }

    @Test func deniedEffectCallsCarryTheContractCodes() {
        let cases: [(LeaseDenial, ToolErrorCode)] = [
            (.notHeld, .leaseNotHeld), (.heldByOther(expiresInMs: 1234), .leaseHeldByOther), (.expired, .leaseExpired),
        ]
        for (denial, code) in cases {
            let error = ToolError(denial.reason, message: denial.message, state: .ok)
            #expect(error.code == code)
        }
        let heldByOther = ToolError(
            LeaseDenial.heldByOther(expiresInMs: 1234).reason, message: "", state: .ok
        ).jsonValue
        #expect(heldByOther["details"] == ["expires_in_ms": 1234])
    }
}
