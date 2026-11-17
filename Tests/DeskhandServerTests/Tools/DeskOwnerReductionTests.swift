import DeskhandCore
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import DeskhandServer

@Suite("DeskOwner: reductions apply one at a time, in the order their signals were read", .timeLimit(.minutes(1)))
struct DeskOwnerReductionTests {
    @Test("a reduction started during a slow signal read reads its signals only after that one applied")
    func reductionsAreSerialized() async throws {
        let race = try await ReductionRace.run()
        #expect(race.seenBySecondRead == .secureInput, "the second reduction read its signals during the first")
    }

    @Test("an older signal reading never applies after a newer one and reopens the state it closed")
    func reductionsApplyInSignalOrder() async throws {
        let race = try await ReductionRace.run()
        #expect(race.final == .ok, "the first reading, secure_input, applied after the second, ok")
    }
}

/// Two reductions on two threads. The first reads `secure_input` and then holds its read until
/// the second reads its signals, `ok`, or until 200 ms pass. With the reductions serialized the
/// second cannot read before the first applies, so the hold always runs out; without, the second
/// reads at once and applies first.
private struct ReductionRace {
    let seenBySecondRead: DeskhandState?
    let final: DeskhandState

    static func run() async throws -> ReductionRace {
        let harness = try ToolHarness()
        let owner = harness.owner
        let firstReading = Event()
        let secondRead = DispatchSemaphore(value: 0)
        let seen = Mutex<DeskhandState?>(nil)

        let first = OnThread {
            owner.reduce(
                signals: {
                    let signals = ToolFixture.signals(holding: [.secureInput])
                    firstReading.fire()
                    _ = secondRead.wait(timeout: .now() + .milliseconds(200))
                    return signals
                }())
        }
        await firstReading.wait()
        let second = OnThread {
            owner.reduce(
                signals: {
                    seen.withLock { $0 = owner.snapshot().state }
                    secondRead.signal()
                    return ToolFixture.signals()
                }())
        }
        _ = await first.value
        _ = await second.value
        return ReductionRace(seenBySecondRead: seen.withLock { $0 }, final: owner.snapshot().state)
    }
}

/// A body run on its own thread, so a reduction that blocks does not hold a thread of the
/// cooperative pool.
private final class OnThread<T: Sendable>: Sendable {
    private let result = Mutex<(value: T?, waiter: CheckedContinuation<T, Never>?)>((nil, nil))

    init(_ body: @escaping @Sendable () -> T) {
        let thread = Thread { [self] in
            let value = body()
            let waiter = self.result.withLock { result in
                result.value = value
                return result.waiter
            }
            waiter?.resume(returning: value)
        }
        thread.start()
    }

    var value: T {
        get async {
            await withCheckedContinuation { continuation in
                let value = result.withLock { result -> T? in
                    if result.value == nil { result.waiter = continuation }
                    return result.value
                }
                if let value { continuation.resume(returning: value) }
            }
        }
    }
}

private final class Event: Sendable {
    private let state = Mutex<(fired: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func fire() {
        let waiters = state.withLock { state in
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let fired = state.withLock { state in
                if !state.fired { state.waiters.append(continuation) }
                return state.fired
            }
            if fired { continuation.resume() }
        }
    }
}
