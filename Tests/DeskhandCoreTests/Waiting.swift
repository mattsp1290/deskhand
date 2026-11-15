import DeskhandCore
import Synchronization

final class Waiters: Sendable {
    private struct Waiter {
        let id: UInt64
        let ready: @Sendable () -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var lastID: UInt64 = 0
        var waiting: [Waiter] = []
        var cancelled: Set<UInt64> = []
    }

    private let state = Mutex(State())

    func wait(until ready: @escaping @Sendable () -> Bool) async {
        let id = state.withLock { state in
            state.lastID += 1
            return state.lastID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let done = state.withLock { state in
                    if state.cancelled.remove(id) != nil || ready() { return true }
                    state.waiting.append(Waiter(id: id, ready: ready, continuation: continuation))
                    return false
                }
                if done { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.waiting.remove(at: index)
            }
            waiter?.continuation.resume()
        }
    }

    func changed() {
        let ready = state.withLock { state in
            var ready: [Waiter] = []
            state.waiting.removeAll { waiter in
                guard waiter.ready() else { return false }
                ready.append(waiter)
                return true
            }
            return ready
        }
        for waiter in ready { waiter.continuation.resume() }
    }
}

func finished<T: Sendable>(_ task: Task<T, Never>) async -> T? {
    let result = Box<T>()
    let waiters = Waiters()
    Task {
        let value = await task.value
        result.set(value)
        waiters.changed()
    }
    await waiters.wait { result.value != nil }
    return result.value
}

final class Box<T: Sendable>: Sendable {
    private let stored = Mutex<T?>(nil)

    var value: T? { stored.withLock { $0 } }

    func set(_ value: T) { stored.withLock { $0 = value } }
}

final class ManualWaitLimits: WaitLimitTimer {
    private struct State {
        var passing = false
        var lastID: UInt64 = 0
        var sleeping: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var cancelled: Set<UInt64> = []
    }

    private let state = Mutex(State())

    func sleep(for limit: Duration) async {
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

    func passing<T>(_ body: () async -> T) async -> T {
        let sleepers = state.withLock { state in
            state.passing = true
            defer { state.sleeping = [:] }
            return Array(state.sleeping.values)
        }
        for sleeper in sleepers { sleeper.resume() }
        let result = await body()
        state.withLock { $0.passing = false }
        return result
    }
}
