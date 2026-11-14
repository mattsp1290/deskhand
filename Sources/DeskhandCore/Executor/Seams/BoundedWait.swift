import Synchronization

/// Waits for `operation` for at most `limit`, and returns `nil` when the limit passed first
/// (contract 11.3, 12.3). The operation runs in a task of its own, so the cancellation of the
/// waiting task, which is how a closed connection reaches a request, does not reach it: an append
/// to the action log is not abandoned because the caller hung up. An operation that outlives the
/// limit is left to finish unobserved.
func awaitBounded<T: Sendable>(within limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { continuation in
        let answer = FirstAnswer(continuation)
        let timeout = Task {
            try? await Task.sleep(for: limit)
            answer.resume(returning: nil)
        }
        Task {
            answer.resume(returning: await operation())
            timeout.cancel()
        }
    }
}

/// Resumes a continuation with whichever answer comes first and ignores the rest.
final class FirstAnswer<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = Mutex(continuation) }

    func resume(returning value: T?) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }
}
