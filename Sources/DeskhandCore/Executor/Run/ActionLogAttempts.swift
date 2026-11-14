import Synchronization

/// The appends to the action log in the order they began, so `log_unavailable` follows the most
/// recent attempt (contract 11.3) although appends that overlap can answer in any order. A result
/// of an attempt older than one already reported is stale and dropped. An attempt that ran out of
/// time is reported as failed; its own late answer may still replace that report, but a report
/// that it ran out of time never replaces its answer.
struct ActionLogAttempts {
    private var started = 0
    private var newest: (attempt: Int, answered: Bool)?

    /// Numbers an append as it begins.
    mutating func start() -> Int {
        started += 1
        return started
    }

    /// Whether the result of `attempt` decides the condition. `answered` is `false` for a wait that
    /// ran out before the writer answered.
    mutating func decides(_ attempt: Int, answered: Bool) -> Bool {
        if let newest {
            guard attempt >= newest.attempt else { return false }
            if attempt == newest.attempt, newest.answered, !answered { return false }
        }
        newest = (attempt, answered)
        return true
    }
}

/// The refusal entry of a call whose intent append failed or ran out of time (contract 11.3,
/// 12.10). It is written only once that append has returned, so an intent the writer commits late
/// is followed by the refusal that says the operation never ran, rather than standing alone after
/// it. An append that never returns leaves the refusal unwritten, as a writer that cannot be
/// reached would.
final class PendingIntent: Sendable {
    private enum Progress {
        case appending
        case appendingWithRefusal(ActionLogRefusal)
        case returned
    }

    private let progress = Mutex(Progress.appending)

    /// Keeps `entry` until the append returns. `false` when it already has: write the entry now.
    func holdRefusal(_ entry: ActionLogRefusal) -> Bool {
        progress.withLock { progress in
            guard case .appending = progress else { return false }
            progress = .appendingWithRefusal(entry)
            return true
        }
    }

    /// The append returned. The refusal entry held meanwhile, to write now.
    func appendReturned() -> ActionLogRefusal? {
        progress.withLock { progress in
            defer { progress = .returned }
            guard case .appendingWithRefusal(let entry) = progress else { return nil }
            return entry
        }
    }
}
