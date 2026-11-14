import DeskhandCore
import Testing

/// The watchdog's interruptions (contract 12.4, 13): they stop the call in the section at its next
/// check, the first in refusal order winning, and only while that call is in the section.
@Suite("Executor: the watchdog's interruptions", .timeLimit(.minutes(1)))
struct InterruptionTests {
    /// The end of the fixture's lease (serial 1), or of a later lease of the same holder (serial 2).
    static func leaseEnd(ofSerial serial: Int) throws -> LeaseEnd {
        var manager = ExecutorFixture.acquired()
        let release = LeaseArguments(holderID: ExecutorFixture.holder, command: .release)
        let acquire = LeaseArguments(holderID: ExecutorFixture.holder, command: .acquire(ttlMs: 30_000))
        let principal = ExecutorFixture.principal
        for _ in 1..<serial {
            _ = manager.apply(release, principal: principal, state: .ok, now: ExecutorFixture.t0)
            _ = manager.apply(acquire, principal: principal, state: .ok, now: ExecutorFixture.t0)
        }
        let ended = try #require(
            manager.apply(release, principal: principal, state: .ok, now: ExecutorFixture.t0).ended)
        #expect(ended.lease.serial == UInt64(serial))
        return ended
    }

    @Test(
        "the end of another lease, arriving first, does not hide a later interruption",
        arguments: [Interruption.userActive(idleMs: 7), .state(.paused)])
    func unrelatedLeaseEndHidesNothing(_ later: Interruption) async throws {
        let unrelated = try Self.leaseEnd(ofSerial: 2)
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        mac.change {
            $0.onSleep = {
                await executor.interrupt(.leaseEnded(unrelated))
                await executor.interrupt(later)
            }
        }
        let answer = await executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "modifiers": ["shift"], "hold_ms": 500]))
        let expected: ToolErrorCode = later == .state(.paused) ? .paused : .userActive
        #expect(answer.code == expected)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 2))
        #expect(mac.read(\.sleeps).count == 1)
    }

    @Test("the end of the lease the call runs under stops it, though the state owner has not caught up")
    func ownLeaseEndStops() async throws {
        let own = try Self.leaseEnd(ofSerial: 1)
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        mac.change { $0.onSleep = { await executor.interrupt(.leaseEnded(own)) } }
        let answer = await executor.perform(try harness.keyboard(["type": "press", "key": "k", "hold_ms": 500]))
        #expect(answer.code == .leaseNotHeld)
        #expect(mac.released == [.named(.k)])
    }

    @Test(
        "the same interruption passed twice, by the state owner and then by the watchdog, stops the call once",
        arguments: [false, true])
    func duplicateInterruptionIsHarmless(leaseEnd: Bool) async throws {
        let own = try Self.leaseEnd(ofSerial: 1)
        let interruption: Interruption = leaseEnd ? .leaseEnded(own) : .state(.secureInput)
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        mac.change {
            $0.onSleep = {
                await executor.interrupt(interruption)
                await executor.interrupt(interruption)
            }
        }
        let answer = await executor.perform(try harness.keyboard(["type": "press", "key": "k", "hold_ms": 500]))
        #expect(answer.code == (leaseEnd ? .leaseNotHeld : .secureInput))
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 1))
        #expect(mac.released == [.named(.k)])
        #expect(await harness.logEntries.map(\.kind) == [.intent, .outcome])
    }

    @Test("an interruption sent while the section is empty does not stop the next operation")
    func interruptionWhileIdleIsIgnored() async throws {
        let harness = try Harness()
        await harness.executor.interrupt(.state(.paused))
        await harness.executor.interrupt(.userActive(idleMs: 4))
        let answer = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "x"]))
        #expect(answer.result?.eventsPosted == 2)
    }

    @Test("an interruption ends with the call it stopped: the next call runs")
    func interruptionLeavesWithTheCall() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        mac.change { $0.onSleep = { await executor.interrupt(.userActive(idleMs: 3)) } }
        let first = await executor.perform(try harness.keyboard(["type": "press", "key": "k", "hold_ms": 300]))
        #expect(first.code == .userActive)
        mac.change { $0.onSleep = nil }
        let second = await executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "hold_ms": 300], operation: "op-2"))
        #expect(second.result?.eventsPosted == 2)
    }

    @Test("an interruption first in refusal order wins over a later cause found at the same poll")
    func interruptionOutranksAPolledCause() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        mac.change { world in
            world.onSleep = {
                mac.change { $0.idleMs = 0 }
                await executor.interrupt(.state(.paused))
            }
        }
        let answer = await executor.perform(try harness.keyboard(["type": "press", "key": "k", "hold_ms": 300]))
        #expect(answer.code == .paused)
        #expect(mac.released == [.named(.k)])
    }
}
