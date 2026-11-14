import Synchronization

/// Waits for `operation` for at most `limit`, and returns `nil` when the limit passed first
/// (contract 11.3, 12.3). The operation runs in a task of its own, so the cancellation of the
/// waiting task, which is how a closed connection reaches a request, does not reach it: an append
/// to the action log is not abandoned because the caller hung up. An operation that outlives the
/// limit runs on, and hands its answer to `late` once it has one.
func awaitBounded<T: Sendable>(
    within limit: Duration, _ operation: @escaping @Sendable () async -> T,
    late: @escaping @Sendable (T) async -> Void = { _ in }
) async -> T? {
    await withCheckedContinuation { continuation in
        let answer = FirstAnswer(continuation)
        let timeout = Task {
            try? await Task.sleep(for: limit)
            answer.resume(returning: nil)
        }
        Task {
            let value = await operation()
            timeout.cancel()
            if !answer.resume(returning: value) { await late(value) }
        }
    }
}

/// Resumes a continuation with whichever answer comes first and ignores the rest.
private final class FirstAnswer<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = Mutex(continuation) }

    /// `false` when an earlier answer already resumed it.
    @discardableResult
    func resume(returning value: T?) -> Bool {
        guard let continuation = continuation.withLock({ $0.take() }) else { return false }
        continuation.resume(returning: value)
        return true
    }
}
