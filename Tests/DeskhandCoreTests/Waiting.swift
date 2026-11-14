import DeskhandCore
import Synchronization

/// Tasks waiting until a condition holds. Each wait ends when its condition holds or when its task
/// is cancelled, which is what a test's time limit does: a wait that would never end fails its
/// test instead of hanging the run.
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

    /// Returns once `ready` holds, checked now and at every ``changed()``, or once the calling task
    /// is cancelled. `ready` must not call ``changed()``.
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

    /// What the conditions read changed: ends every wait whose condition now holds. Call it after
    /// the change, outside any lock a condition takes.
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

/// `task`'s value, or `nil` once the calling task is cancelled, as at the end of its test's time
/// limit: awaiting a call that never answers then fails the test instead of hanging the run.
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

/// One value, set once.
final class Box<T: Sendable>: Sendable {
    private let stored = Mutex<T?>(nil)

    var value: T? { stored.withLock { $0 } }

    func set(_ value: T) { stored.withLock { $0 = value } }
}

/// The executor's wait limits (``WaitLimitTimer``), which pass only when the test says so: until
/// then a bounded wait waits for its answer however slow the machine is, and once the test lets
/// the limits pass, the waits that hang end at once.
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

    /// Runs `body` with every limit passing, the waits running now and those that start: each ends
    /// as if its limit had passed. Limits are held again when `body` returns.
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
