import Synchronization
import Testing

@testable import DeskhandCore

@Suite(.timeLimit(.minutes(1))) struct DisposableReadTests {
    final class Payload: Sendable {
        let bytes = [UInt8](repeating: 7, count: 1_048_576)
        let released: Box<Bool>
        let changes: Waiters

        init(released: Box<Bool>, changes: Waiters) {
            self.released = released
            self.changes = changes
        }

        deinit {
            released.set(true)
            changes.changed()
        }
    }

    @Test func cooperativeTimeoutCancelsAndReleasesPayload() async throws {
        let limits = ManualWaitLimits()
        let harness = try Harness(waitTimer: limits)
        let sleeper = ManualWaitLimits()
        let started = Box<Bool>()
        let released = Box<Bool>()
        let cancelled = Box<Bool>()
        let changes = Waiters()
        let read = Task {
            await harness.executor.boundedRead {
                let payload = Payload(released: released, changes: changes)
                started.set(true)
                changes.changed()
                await sleeper.sleep(for: .seconds(3600))
                cancelled.set(Task.isCancelled)
                return payload.bytes.count
            }
        }
        await changes.wait { started.value == true }
        #expect(await limits.passing { await finished(read) } == .some(nil))
        await changes.wait { released.value == true }
        #expect(cancelled.value == true)
        if let completion = await harness.executor.outstandingRead?.task { await completion.value }
        #expect(await harness.executor.boundedRead { 42 } == 42)
    }

    @Test func noncooperatingReadCannotAccumulateAndLateCompletionReleasesSlot() async throws {
        let limits = ManualWaitLimits()
        let harness = try Harness(waitTimer: limits)
        let gate = Gate()
        let invocations = Mutex(0)
        let read = Task {
            await harness.executor.boundedRead {
                invocations.withLock { $0 += 1 }
                await gate.pass()
                return 7
            }
        }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        #expect(
            await harness.executor.boundedRead {
                invocations.withLock { $0 += 1 }
                return 8
            } == nil)
        #expect(await limits.passing { await finished(read) } == .some(nil))
        for _ in 0..<8 {
            #expect(
                await harness.executor.boundedRead {
                    invocations.withLock { $0 += 1 }
                    return 9
                } == nil)
        }
        #expect(invocations.withLock { $0 } == 1)
        let completion = try #require(await harness.executor.outstandingRead?.task)
        await gate.open()
        await completion.value
        #expect(await harness.executor.boundedRead { 10 } == 10)
        #expect(await harness.executor.boundedRead { 11 } == 11)
    }

    @Test func completionAndTimeoutOverlapLeavesAReusableSlot() async throws {
        for _ in 0..<20 {
            let limits = ManualWaitLimits()
            let harness = try Harness(waitTimer: limits)
            let gate = Gate()
            let read = Task {
                await harness.executor.boundedRead {
                    await gate.pass()
                    return 12
                }
            }
            var arrivals = gate.arrived.makeAsyncIterator()
            _ = await arrivals.next()
            let completion = try #require(await harness.executor.outstandingRead?.task)
            let answer = await limits.passing {
                await gate.open()
                return await read.value
            }
            #expect(answer == nil || answer == 12)
            await completion.value
            #expect(await harness.executor.boundedRead { 13 } == 13)
        }
    }
}
