import DeskhandCore
import Synchronization

public final class ManualWaitLimits: WaitLimitTimer {
    private struct State {
        var passing = false
        var lastID: UInt64 = 0
        var sleeping: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var cancelled: Set<UInt64> = []
    }

    private let state = Mutex(State())

    public init() {}

    public func sleep(for limit: Duration) async {
        let id = state.withLock { state in
            state.lastID += 1
            return state.lastID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let done = state.withLock { state in
                    if state.cancelled.remove(id) != nil || state.passing { return true }
                    state.sleeping[id] = continuation
                    return false
                }
                if done { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                guard let sleeper = state.sleeping.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return CheckedContinuation<Void, Never>?.none
                }
                return sleeper
            }
            sleeper?.resume()
        }
    }

    public func passing<T>(_ body: () async throws -> T) async rethrows -> T {
        let sleepers = state.withLock { state in
            state.passing = true
            defer { state.sleeping = [:] }
            return Array(state.sleeping.values)
        }
        for sleeper in sleepers { sleeper.resume() }
        defer { state.withLock { $0.passing = false } }
        return try await body()
    }
}
