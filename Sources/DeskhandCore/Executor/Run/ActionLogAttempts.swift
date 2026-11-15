import Synchronization

struct ActionLogAttempts {
    private var started = 0
    private var newest: (attempt: Int, answered: Bool)?

    mutating func start() -> Int {
        started += 1
        return started
    }

    mutating func decides(_ attempt: Int, answered: Bool) -> Bool {
        if let newest {
            guard attempt >= newest.attempt else { return false }
            if attempt == newest.attempt, newest.answered, !answered { return false }
        }
        newest = (attempt, answered)
        return true
    }
}

final class PendingIntent: Sendable {
    private enum Progress {
        case appending
        case appendingWithRefusal(ActionLogRefusal)
        case returned
    }

    private let progress = Mutex(Progress.appending)

    func holdRefusal(_ entry: ActionLogRefusal) -> Bool {
        progress.withLock { progress in
            guard case .appending = progress else { return false }
            progress = .appendingWithRefusal(entry)
            return true
        }
    }

    func appendReturned() -> ActionLogRefusal? {
        progress.withLock { progress in
            defer { progress = .returned }
            guard case .appendingWithRefusal(let entry) = progress else { return nil }
            return entry
        }
    }
}
