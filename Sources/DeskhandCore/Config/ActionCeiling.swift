/// The per-Mac ceiling on effect calls, `ACTIONS_PER_MINUTE` (contract 9.5 "The action ceiling",
/// 16, Appendix A items 11 and 55). One counter per Mac, across every principal and holder, over a
/// sliding 60 s window. It counts every admitted call and every call refused before admission with
/// `denied_app` or `denied_shortcut`, so the app policy cannot be probed without limit. No other
/// refusal counts, and a replay does not count.
///
/// A sliding window over counted times rather than a refilling token bucket, because a bucket
/// of N tokens refilled at N a minute lets almost 2N calls through within one minute.
///
/// Refusing and counting are separate steps: ``refusal(at:)`` is the step-7 check and counts
/// nothing; ``recordAdmission(at:)`` counts a call that passed every check, and
/// ``recordRefusal(_:at:)`` one that the policy refused.
/// A value type with no clock of its own: the one owner of effect admission keeps it and calls the
/// methods in order for each call, so no other admission can come between them.
public struct ActionCeiling: Sendable {
    public static let windowMs: Int64 = 60_000

    public let actionsPerMinute: Int
    /// Counted times in the window, oldest first.
    private var counted: [Timestamp] = []

    /// A ceiling below one call a minute is taken as one.
    public init(actionsPerMinute: Int) {
        self.actionsPerMinute = max(1, actionsPerMinute)
    }

    public init(limits: Limits) { self.init(actionsPerMinute: limits.actionsPerMinute) }

    /// `rate_limited` with the time until the oldest counted call leaves the window, or `nil` when
    /// a call could be admitted at `now`. Counts nothing; it only forgets what has left the window.
    public mutating func refusal(at now: Timestamp) -> ToolErrorReason? {
        forget(before: now)
        guard counted.count >= actionsPerMinute else { return nil }
        let blocking = counted[counted.count - actionsPerMinute]
        let retryAfter = blocking.millisecondsSinceEpoch + Self.windowMs - now.millisecondsSinceEpoch
        return .rateLimited(retryAfterMs: Int(retryAfter))
    }

    /// Counts a call that was admitted at `now`.
    public mutating func recordAdmission(at now: Timestamp) {
        forget(before: now)
        counted.append(now)
    }

    /// Counts a call refused before admission at `now` when the refusal is `denied_app` or
    /// `denied_shortcut`, and returns whether it counted.
    @discardableResult
    public mutating func recordRefusal(_ reason: ToolErrorReason, at now: Timestamp) -> Bool {
        guard reason.code == .deniedApp || reason.code == .deniedShortcut else { return false }
        recordAdmission(at: now)
        return true
    }

    /// Drops what no longer counts at `now`.
    ///
    /// A counted time later than `now` means the clock was stepped back. It is moved to `now`, so the
    /// step never lets extra calls through and delays the next one by at most one window. A step
    /// forward ends the window early by the size of the step.
    private mutating func forget(before now: Timestamp) {
        counted = counted.map { min($0, now) }.filter {
            now.millisecondsSinceEpoch - $0.millisecondsSinceEpoch < Self.windowMs
        }
    }
}
