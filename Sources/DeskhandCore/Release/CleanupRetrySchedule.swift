/// What an attempt at the owed releases depended on. When it changes, the next attempt is due at
/// once: deskhand tries again on every change of state (contract 11.2).
public struct CleanupContext: Hashable, Sendable {
    public let activeStates: ActiveStates
    public let authorization: CleanupAuthorization

    public init(activeStates: ActiveStates, conditions: Set<Condition>) {
        self.activeStates = activeStates
        authorization = CleanupAuthorization(active: activeStates, conditions: conditions)
    }

    /// As `snapshot` stands at its own reading.
    public init(_ snapshot: DeskSnapshot) {
        self.init(
            activeStates: snapshot.report.activeStates(at: snapshot.reading), conditions: snapshot.report.conditions)
    }
}

/// When the releases deskhand owes are tried again (contract 11.2, Appendix A item 33): at once
/// when nothing has been tried yet or the context changed since the last attempt, and otherwise
/// ``interval`` after it. Pure: the caller passes the time and the context and records each attempt.
public struct CleanupRetrySchedule: Hashable, Sendable {
    /// "At least once a second."
    public static let interval: Duration = .seconds(1)

    public struct Attempt: Hashable, Sendable {
        public let instant: ContinuousClock.Instant
        public let context: CleanupContext
    }

    /// The latest attempt since releases came to be owed; `nil` before the first.
    public private(set) var lastAttempt: Attempt?

    public init() {}

    /// When the next attempt is due, never before `now`.
    public func nextRetry(at now: ContinuousClock.Instant, context: CleanupContext) -> ContinuousClock.Instant {
        guard let lastAttempt, lastAttempt.context == context else { return now }
        return max(now, lastAttempt.instant.advanced(by: Self.interval))
    }

    public func isDue(at now: ContinuousClock.Instant, context: CleanupContext) -> Bool {
        nextRetry(at: now, context: context) <= now
    }

    public mutating func didAttempt(at instant: ContinuousClock.Instant, context: CleanupContext) {
        lastAttempt = Attempt(instant: instant, context: context)
    }

    /// Nothing is owed any more, so the next time something is, it is tried at once.
    public mutating func reset() { lastAttempt = nil }
}
