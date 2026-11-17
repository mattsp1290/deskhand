import DeskhandCore
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import DeskhandServer

/// Pins the serialization ``DeskOwner/reduce(signals:command:)`` already has; it does not drive the
/// watchdog.
@Suite("DeskOwner: reductions apply one at a time, in the order their signals were read", .timeLimit(.minutes(1)))
struct DeskOwnerReductionTests {
    /// Two reductions on two threads. The first reads `secure_input` and then holds its read until
    /// the second reads its signals, `ok`, or until 200 ms pass. With the reductions serialized the
    /// second cannot read before the first applies, so the hold always runs out; without, the
    /// second reads at once and usually applies first.
    @Test("a reduction started during a slow signal read reads its signals only after that one applied")
    func reductionsAreSerializedInSignalOrder() async throws {
        let harness = try ToolHarness()
        let owner = harness.owner
        let firstReading = Latch()
        let secondRead = DispatchSemaphore(value: 0)
        let seen = Mutex<DeskhandState?>(nil)

        let first = onThread {
            owner.reduce(
                signals: {
                    let signals = ToolFixture.signals(holding: [.secureInput])
                    firstReading.open()
                    _ = secondRead.wait(timeout: .now() + .milliseconds(200))
                    return signals
                }())
        }
        await firstReading.wait()
        let second = onThread {
            owner.reduce(
                signals: {
                    seen.withLock { $0 = owner.snapshot().state }
                    secondRead.signal()
                    return ToolFixture.signals()
                }())
        }
        _ = await first.value
        _ = await second.value
        #expect(seen.withLock { $0 } == .secureInput, "the second reduction read its signals during the first")
        #expect(owner.snapshot().state == .ok, "the first reading, secure_input, applied after the second, ok")
    }
}

/// Runs `body` on its own thread, so a reduction that blocks does not hold a thread of the
/// cooperative pool.
private func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) -> Task<T, Never> {
    Task { await withCheckedContinuation { done in Thread { done.resume(returning: body()) }.start() } }
}
