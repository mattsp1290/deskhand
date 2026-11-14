import DeskhandCore
import Testing

/// Contract 11.2 and Appendix A item 33: deskhand tries pending cleanup again on every change of
/// state and at least once a second.
@Suite("Release: the retry schedule", .timeLimit(.minutes(1)))
struct CleanupRetryScheduleTests {
    static let start = ExecutorFixture.t0.monotonic
    static let locked = CleanupContext(activeStates: ActiveStates([.locked]), conditions: [])
    static let unlocked = CleanupContext(activeStates: .none, conditions: [])

    static func at(_ milliseconds: Int64) -> ContinuousClock.Instant { start.advanced(by: .milliseconds(milliseconds)) }

    @Test("with no attempt yet, a retry is due at once")
    func dueAtOnce() {
        let schedule = CleanupRetrySchedule()
        #expect(schedule.isDue(at: Self.start, context: Self.locked))
        #expect(schedule.nextRetry(at: Self.start, context: Self.locked) == Self.start)
    }

    @Test("after an attempt the next is due one second later while nothing changes")
    func oncePerSecond() {
        var schedule = CleanupRetrySchedule()
        schedule.didAttempt(at: Self.start, context: Self.locked)
        #expect(CleanupRetrySchedule.interval == .seconds(1))
        #expect(schedule.nextRetry(at: Self.at(10), context: Self.locked) == Self.at(1000))
        #expect(schedule.isDue(at: Self.at(999), context: Self.locked) == false)
        #expect(schedule.isDue(at: Self.at(1000), context: Self.locked))
        #expect(schedule.nextRetry(at: Self.at(4000), context: Self.locked) == Self.at(4000))
    }

    @Test("a change of state or of the blocking conditions makes a retry due at once")
    func changeOfContext() {
        var schedule = CleanupRetrySchedule()
        schedule.didAttempt(at: Self.start, context: Self.locked)
        #expect(schedule.isDue(at: Self.at(1), context: Self.unlocked))
        #expect(schedule.nextRetry(at: Self.at(1), context: Self.unlocked) == Self.at(1))
        let lockedAndPaused = CleanupContext(activeStates: ActiveStates([.locked, .paused, .disarmed]), conditions: [])
        #expect(lockedAndPaused.authorization == Self.locked.authorization)
        #expect(schedule.isDue(at: Self.at(1), context: lockedAndPaused))
        let loginWindow = CleanupContext(activeStates: ActiveStates([.notConsole]), conditions: [.loginWindow])
        let console = CleanupContext(activeStates: ActiveStates([.notConsole]), conditions: [])
        schedule.didAttempt(at: Self.at(2), context: console)
        #expect(schedule.isDue(at: Self.at(3), context: loginWindow))
    }

    @Test("conditions that do not block cleanup are not a change")
    func otherConditions() {
        var schedule = CleanupRetrySchedule()
        schedule.didAttempt(at: Self.start, context: Self.locked)
        let noisy = CleanupContext(
            activeStates: ActiveStates([.locked]), conditions: [.cleanupPending, .userActive, .logUnavailable])
        #expect(noisy == Self.locked)
        #expect(schedule.isDue(at: Self.at(500), context: noisy) == false)
    }

    @Test("once reset, the next retry is due at once again")
    func reset() {
        var schedule = CleanupRetrySchedule()
        schedule.didAttempt(at: Self.start, context: Self.locked)
        schedule.reset()
        #expect(schedule.lastAttempt == nil)
        #expect(schedule.isDue(at: Self.at(1), context: Self.locked))
    }
}
