import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct AllowanceCacheTests {
    let start = ContinuousClock.now

    func cache(_ probe: FakeAllowanceProbe) -> AllowanceCache {
        AllowanceCache(reader: AllowanceSample.reader(probe))
    }

    @Test func readsTheFileAtMostOncePerMaxAge() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened())
        var cache = cache(probe)
        let now = AllowanceSample.during
        for elapsed in [0, 1, 500, 999] {
            #expect(cache.verdict(now: now, at: start + .milliseconds(elapsed)).isValid)
        }
        #expect(probe.calls.count == 1)
        #expect(cache.verdict(now: now, at: start + AllowanceCache.maxAge).isValid)
        #expect(probe.calls.count == 2)
    }

    @Test func neverServesAValidVerdictAtOrAfterExpiry() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened())
        var cache = cache(probe)
        let expiresAt = AllowanceSample.expiresAt
        #expect(cache.verdict(now: expiresAt.adding(milliseconds: -1), at: start) == .valid(expiresAt: expiresAt))
        #expect(cache.verdict(now: expiresAt, at: start + .milliseconds(1)) == .invalid(.expired))
        #expect(
            cache.verdict(now: expiresAt.adding(milliseconds: 500), at: start + .milliseconds(2)) == .invalid(.expired))
        #expect(probe.calls.count == 1)
    }

    @Test func becomesValidAtNotBeforeFromTheSameCopy() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened())
        var cache = cache(probe)
        let notBefore = AllowanceSample.notBefore
        #expect(cache.verdict(now: notBefore.adding(milliseconds: -1), at: start) == .invalid(.notYetValid))
        #expect(cache.verdict(now: notBefore, at: start + .milliseconds(1)).isValid)
        #expect(probe.calls.count == 1)
    }

    @Test func revocationIsSeenOnceTheCopyIsMaxAgeOld() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened())
        var cache = cache(probe)
        let now = AllowanceSample.during
        #expect(cache.verdict(now: now, at: start).isValid)
        probe.set(.fileFailed(directory: AllowanceSample.rootDirectory, error: .notFound))
        #expect(cache.verdict(now: now, at: start + .milliseconds(999)).isValid)
        #expect(cache.verdict(now: now, at: start + .milliseconds(1000)) == .missing)
    }

    @Test func aReplacementMovesTheDeadlineEitherWay() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened())
        var cache = cache(probe)
        let now = AllowanceSample.during
        #expect(cache.verdict(now: now, at: start) == .valid(expiresAt: AllowanceSample.expiresAt))
        probe.set(AllowanceSample.opened(contents: AllowanceSample.json(expiresAt: #""2026-11-14T15:05:00Z""#)))
        #expect(
            cache.verdict(now: now, at: start + .seconds(1))
                == .valid(expiresAt: AllowanceSample.notBefore.adding(milliseconds: 300_000)))
        probe.set(AllowanceSample.opened(contents: AllowanceSample.json(expiresAt: #""2026-11-14T15:01:30Z""#)))
        #expect(
            cache.verdict(now: now, at: start + .seconds(2))
                == .valid(expiresAt: AllowanceSample.notBefore.adding(milliseconds: 90_000)))
    }

    @Test func invalidateForcesTheNextRead() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened())
        var cache = cache(probe)
        let now = AllowanceSample.during
        #expect(cache.verdict(now: now, at: start).isValid)
        probe.set(.directoryFailed(.notFound))
        cache.invalidate()
        #expect(cache.verdict(now: now, at: start + .milliseconds(1)) == .missing)
        #expect(probe.calls.count == 2)
    }

    @Test func anInstantBeforeTheReadIsNotTrusted() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened())
        var cache = cache(probe)
        let now = AllowanceSample.during
        _ = cache.verdict(now: now, at: start + .seconds(5))
        _ = cache.verdict(now: now, at: start)
        #expect(probe.calls.count == 2)
    }

    @Test func cachesAnInvalidFileForTheSameMaxAge() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened(contents: "{"))
        var cache = cache(probe)
        let now = AllowanceSample.during
        #expect(cache.verdict(now: now, at: start) == .invalid(.malformedJSON))
        probe.set(AllowanceSample.opened())
        #expect(cache.verdict(now: now, at: start + .milliseconds(999)) == .invalid(.malformedJSON))
        #expect(cache.verdict(now: now, at: start + .milliseconds(1000)).isValid)
    }
}
