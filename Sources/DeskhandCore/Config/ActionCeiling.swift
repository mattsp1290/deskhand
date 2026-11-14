/// The per-Mac ceiling on effect calls, `ACTIONS_PER_MINUTE` (contract 9.5 step 6, 16, Appendix A
/// item 11): at most that many calls are admitted in any 60 s window. There is one ceiling per Mac,
/// not per principal or holder.
///
/// A sliding window over admission times rather than a refilling token bucket, because a bucket
/// of N tokens refilled at N a minute lets almost 2N calls through within one minute.
///
/// Refusing and counting are separate steps: ``refusal(at:)`` is the step-6 check and counts
/// nothing, and only a call that passes every check (contract 9.5) is counted, by
/// ``recordAdmission(at:)``.
/// A value type with no clock of its own: the one owner of effect admission keeps it and calls the
/// two methods in order for each call, so no other admission can come between them.
public struct ActionCeiling: Sendable {
    public static let windowMs: Int64 = 60_000

    public let actionsPerMinute: Int
    /// Admission times in the window, oldest first.
    private var admissions: [Timestamp] = []

    public init(actionsPerMinute: Int) {
        precondition(actionsPerMinute > 0, "the action ceiling must admit at least one call a minute")
        self.actionsPerMinute = actionsPerMinute
    }

    public init(limits: Limits) { self.init(actionsPerMinute: limits.actionsPerMinute) }

    /// `rate_limited` with the earliest time a call could be admitted, or `nil` when one could be
    /// admitted at `now`. Counts nothing; it only forgets admissions that have left the window.
    public mutating func refusal(at now: Timestamp) -> ToolErrorReason? {
        forget(before: now)
        guard admissions.count >= actionsPerMinute else { return nil }
        let blocking = admissions[admissions.count - actionsPerMinute]
        let retryAfter = blocking.millisecondsSinceEpoch + Self.windowMs - now.millisecondsSinceEpoch
        return .rateLimited(retryAfterMs: Int(retryAfter))
    }

    /// Counts a call that was admitted at `now`.
    public mutating func recordAdmission(at now: Timestamp) {
        forget(before: now)
        admissions.append(now)
    }

    /// Drops the admissions that no longer count at `now`.
    ///
    /// An admission later than `now` means the clock was stepped back. It is moved to `now`, so the
    /// step never lets extra calls through and delays the next one by at most one window. A step
    /// forward ends the window early by the size of the step.
    private mutating func forget(before now: Timestamp) {
        admissions = admissions.map { min($0, now) }.filter {
            now.millisecondsSinceEpoch - $0.millisecondsSinceEpoch < Self.windowMs
        }
    }
}
