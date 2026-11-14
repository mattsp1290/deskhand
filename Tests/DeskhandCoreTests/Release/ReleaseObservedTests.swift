import DeskhandCore
import Testing

/// Contract 10.4: a release is an event deskhand posted, so the arming lookback runs from the last
/// one, whether it ended an abort or went out later.
@Suite("Release: releases are posted events")
struct ReleaseObservedTests {
    @Test("every event and every release is reported as posted, at the time it went out")
    func releasesAreReportedAsPosted() async throws {
        let mac = FakeMac { $0.afterPost[2] = { world, _ in world.idleMs = 0 } }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "a", "modifiers": ["shift"], "hold_ms": 300]))
        #expect(answer.code == .userActive)
        #expect(mac.released == [.named(.a), .modifierKey(.shift)])
        let (observed, posts, releases) = mac.read { ($0.observedPosts, $0.postTimes, $0.releaseTimes) }
        #expect(observed == posts + releases)
    }

    @Test("a release posted later, after a lock, is reported as posted when it goes out")
    func deferredReleaseIsReportedAsPosted() async throws {
        let mac = FakeMac {
            $0.afterPost[2] = { world, now in world.report = ExecutorFixture.report([.locked], at: now) }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "a", "modifiers": ["shift"], "hold_ms": 300]))
        #expect(answer.code == .locked)
        #expect(mac.released.isEmpty)
        mac.advance(byMilliseconds: 4_000)
        mac.change { $0.report = ExecutorFixture.okReport }
        guard case .attempted(.complete) = await harness.executor.releaseOwedInput() else {
            Issue.record("the owed releases were not posted")
            return
        }
        let (observed, posts, releases) = mac.read { ($0.observedPosts, $0.postTimes, $0.releaseTimes) }
        #expect(releases.count == 2)
        #expect(observed == posts + releases)
    }
}
