import Synchronization

/// Measures the limit of the executor's bounded waits (``InputExecutor/Configuration/waitLimit``):
/// ``TaskSleepTimer`` in the app. A test supplies one whose limits pass only when it says so, so
/// that no outcome it checks depends on how fast the machine runs.
public protocol WaitLimitTimer: Sendable {
    /// Returns once `limit` has passed, or earlier when the calling task is cancelled.
    func sleep(for limit: Duration) async
}

extension TaskSleepTimer: WaitLimitTimer {}

struct WaitLimit: Sendable {
    let duration: Duration
    let timer: any WaitLimitTimer
}

func awaitBounded<T: Sendable>(
    within limit: WaitLimit, _ operation: @escaping @Sendable () async -> T,
    late: @escaping @Sendable (T) async -> Void = { _ in }
) async -> T? {
    await withCheckedContinuation { continuation in
        let answer = FirstAnswer(continuation)
        let timeout = Task {
            await limit.timer.sleep(for: limit.duration)
            guard !Task.isCancelled else { return }
            answer.resume(returning: nil)
        }
        Task {
            let value = await operation()
            let wasFirst = answer.resume(returning: value)
            timeout.cancel()
            if !wasFirst { await late(value) }
        }
    }
}

final class FirstAnswer<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = Mutex(continuation) }

    @discardableResult
    func resume(returning value: T?) -> Bool {
        guard let continuation = continuation.withLock({ $0.take() }) else { return false }
        continuation.resume(returning: value)
        return true
    }
}

struct OutstandingRead: Sendable {
    let id: ObjectIdentifier
    let task: Task<Void, Never>
}

extension InputExecutor {
    func boundedRead<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T? {
        guard outstandingRead == nil else { return nil }
        return await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            let id = ObjectIdentifier(answer)
            let timeout = Task {
                await waitLimit.timer.sleep(for: waitLimit.duration)
                guard !Task.isCancelled, outstandingRead?.id == id else { return }
                if answer.resume(returning: nil) { outstandingRead?.task.cancel() }
            }
            let task = Task {
                let value = await operation()
                if outstandingRead?.id == id { outstandingRead = nil }
                answer.resume(returning: value)
                timeout.cancel()
            }
            outstandingRead = OutstandingRead(id: id, task: task)
        }
    }
}
