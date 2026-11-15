import DeskhandCore
import Synchronization
import Testing

@Suite("Release: authorization per release and per operation", .timeLimit(.minutes(1)))
struct ReleaseAuthorizationTests {
    @Test("an abort asks for authorization before every release: a lock after the first stops the rest")
    func abortAsksAuthorizationBeforeEveryRelease() async throws {
        let mac = HeldChord.mac(abortingWith: [.displayAsleep])
        var overrides = Harness.Overrides()
        overrides.poster = LockAfterFirstRelease(mac: mac)
        let harness = try Harness(mac: mac, overrides: overrides)
        #expect(await harness.executor.perform(try harness.keyboard(HeldChord.action)).code == .displayAsleep)
        #expect(mac.released == [.named(.k)])
        #expect(await harness.executor.owesReleases)
    }

    @Test("a retry asks for authorization before every release: a lock after the first stops the rest")
    func retryAsksAuthorizationBeforeEveryRelease() async throws {
        let mac = FakeMac()
        try mac.leaveInLedger(HeldChord.pressed)
        var overrides = Harness.Overrides()
        overrides.poster = LockAfterFirstRelease(mac: mac)
        let harness = try Harness(mac: mac, overrides: overrides)
        guard case .attempted(.deferred([.locked]))? = await harness.executor.retryCleanup(now: mac.reading) else {
            Issue.record("released on after the lock")
            return
        }
        #expect(mac.released == [.named(.k)])
    }

    @Test("a clear that reached the disk but reported failure does not swallow a later operation's release")
    func staleUnclearedSetDoesNotSwallowALaterRelease() async throws {
        let mac = FakeMac {
            $0.afterPost[1] = { world, now in world.report = ExecutorFixture.report([.displayAsleep], at: now) }
        }
        let store = LandingFaultStore(mac: mac)
        var overrides = Harness.Overrides()
        overrides.ledgerStore = store
        let harness = try Harness(mac: mac, overrides: overrides)
        let executor = harness.executor
        mac.change { $0.onSleep = { store.armed.withLock { $0 = true } } }
        let press: JSONValue = ["type": "press", "key": "k", "hold_ms": 300]
        #expect(await executor.perform(try harness.keyboard(press)).code == .displayAsleep)
        #expect(mac.released == [.named(.k)])
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(await executor.storesAvailable == false)

        store.armed.withLock { $0 = false }
        mac.setState([])
        #expect(await executor.reloadUnavailableStores())
        #expect(await executor.owesReleases == false)

        mac.change {
            $0.onSleep = nil
            $0.afterPost[2] = { world, now in world.report = ExecutorFixture.report([.locked], at: now) }
        }
        #expect(await executor.perform(try harness.keyboard(press, operation: "op-2")).code == .locked)
        #expect(mac.heldDown == [.named(.k)])
        mac.setState([])
        _ = await executor.retryCleanup(now: mac.reading)
        #expect(mac.heldDown.isEmpty, "k was cleared from the ledger without a release")
        #expect(mac.released == [.named(.k), .named(.k)])
    }
}

private final class LandingFaultStore: HeldInputStore, Sendable {
    let mac: FakeMac
    let armed = Mutex(false)

    init(mac: FakeMac) { self.mac = mac }

    func load() throws -> [UInt8]? { try mac.ledgerStore.load() }

    func replace(with bytes: [UInt8]) throws {
        try mac.ledgerStore.replace(with: bytes)
        if armed.withLock({ $0 }) { throw FakeFault() }
    }
}

private struct LockAfterFirstRelease: EventPoster {
    let mac: FakeMac

    func post(_ event: InputEvent) throws { try mac.post(event) }

    func postRelease(_ input: HeldInput) throws {
        try mac.postRelease(input)
        if mac.released.count == 1 { mac.setState([.locked]) }
    }
}
