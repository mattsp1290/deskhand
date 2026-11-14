import DeskhandCore
import Testing

/// Holds and the times an operation reports (contract 6.4, 6.5, 6.7, 10.4, 13).
@Suite("Executor: holds and posting times", .timeLimit(.minutes(1)))
struct HoldTests {
    static func isKeyDown(_ event: InputEvent) -> Bool { if case .keyDown = event { true } else { false } }
    static func isKeyUp(_ event: InputEvent) -> Bool { if case .keyUp = event { true } else { false } }
    static func isButtonDown(_ event: InputEvent) -> Bool { if case .buttonDown = event { true } else { false } }
    static func isButtonUp(_ event: InputEvent) -> Bool { if case .buttonUp = event { true } else { false } }

    /// Makes the identity read of the check before event `after + 1` take `milliseconds`.
    static func slowCheck(after event: Int, milliseconds: Int64) -> FakeMac {
        FakeMac {
            $0.afterPost[event] = { world, _ in
                world.duringIdentityRead = { world, _ in world.offsetMs += milliseconds }
            }
        }
    }

    @Test("hold_ms runs from the key-down's post, however long the check before it took")
    func holdMsIsAMinimum() async throws {
        let mac = Self.slowCheck(after: 1, milliseconds: 200)
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "a", "modifiers": ["shift"], "hold_ms": 100]))
        #expect(answer.result?.eventsPosted == 4)
        let held = try #require(mac.heldFor(from: Self.isKeyDown, to: Self.isKeyUp))
        #expect(held >= .milliseconds(100), "key held for \(held), hold_ms 100")
    }

    @Test("duration_ms runs from the button-down's post, and completed_at is the last post")
    func durationMsIsAMinimum() async throws {
        let mac = Self.slowCheck(after: 1, milliseconds: 400)
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.pointer([
                "type": "drag", "path": [["x": 10, "y": 10], ["x": 10, "y": 10]], "duration_ms": 300,
            ]))
        let result = try #require(answer.result)
        #expect(result.eventsPosted == 3)
        let held = try #require(mac.heldFor(from: Self.isButtonDown, to: Self.isButtonUp))
        #expect(held >= .milliseconds(300), "button held for \(held), duration_ms 300")
        let lastPost = try #require(mac.read(\.postTimes).last)
        let milliseconds = Int64(ExecutorFixture.t0.monotonic.duration(to: lastPost) / .milliseconds(1))
        #expect(result.completedAt == ExecutorFixture.t0.wall.adding(milliseconds: milliseconds))
    }

    @Test("while a key is held, the person's input stops the operation at the next poll")
    func holdChecksAtEveryPoll() async throws {
        let mac = FakeMac()
        mac.change { $0.onSleep = { mac.change { $0.idleMs = 10 } } }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "hold_ms": 5000]))
        #expect(answer.code == .userActive)
        #expect(mac.read(\.sleeps).count == 1, "slept \(mac.read(\.sleeps).count) times before noticing")
        #expect(mac.released == [.named(.k)])
    }

    @Test("a hold wakes for the lease's deadline instead of sleeping a whole poll past it")
    func holdWakesForDeadline() async throws {
        let mac = FakeMac { $0.lease = ExecutorFixture.acquired(ttlMs: 5_000) }
        let harness = try Harness(mac: mac)
        // The key goes down 30 ms after the lease was acquired, so a 5 s hold would outlast it.
        await harness.onLog(.intent) { mac.advance(byMilliseconds: 30) }
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "hold_ms": 5000]))
        #expect(answer.code == .leaseExpired)
        let slept = mac.read(\.sleeps).reduce(Duration.zero, +)
        #expect(slept <= .milliseconds(4_970), "slept \(slept)")
    }

    @Test("a timer that returns early only makes a hold poll more often")
    func earlyTimerKeepsTheHold() async throws {
        let mac = FakeMac()
        // Every sleep returns after at most 10 ms, as ExecutionTimer allows; the clock still advances.
        mac.change { world in
            world.onSleep = {
                mac.change { world in
                    let asked = Int64(((world.sleeps.last ?? .zero) / .milliseconds(1)).rounded(.up))
                    world.offsetMs -= max(0, asked - 10)
                }
            }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "hold_ms": 300]))
        #expect(answer.result?.eventsPosted == 2, "\(String(describing: answer.toolError?.message))")
        #expect(mac.read(\.sleeps).count > 3 + InputExecutor.holdPollSlack)
        let held = try #require(mac.heldFor(from: Self.isKeyDown, to: Self.isKeyUp))
        #expect(held >= .milliseconds(300), "key held for \(held), hold_ms 300")
    }

    @Test("a hold whose clock reading does not advance ends as a fault, and releases the key")
    func frozenClockEndsHold() async throws {
        let mac = FakeMac { $0.frozenOffsetMs = 0 }
        let harness = try Harness(mac: mac)
        // Closes long after the bound, so a hold that ignores it ends as cancelled instead of never.
        let connection = FakeConnection(openReads: 100)
        let answer = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "hold_ms": 300], connection: connection))
        #expect(answer.code == .internalError)
        #expect(answer.operation == OperationView(status: .failed, eventsPosted: 1))
        #expect(mac.read(\.sleeps).count == 3 + InputExecutor.holdPollSlack)
        #expect(mac.released == [.named(.k)])
        #expect(mac.ledgerOnDisk.isEmpty)
    }
}
