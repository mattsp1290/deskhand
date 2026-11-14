import DeskhandCore
import Testing

/// Cleanup from the ledger across restarts, crashes and a disk that refuses writes (contract 12.3,
/// 12.7 items 5 and 6, 12.9 step 5).
@Suite("Release: restart cleanup and ledger faults")
struct RestartCleanupTests {
    static let leftOver: [HeldInput] = [.modifierKey(.command), .modifierKey(.shift), .button(.left), .named(.a)]

    @Test("restart cleanup releases everything the ledger holds, newest first, at the first retry")
    func restartReleasesAll() async throws {
        let mac = FakeMac()
        try mac.leaveInLedger(Self.leftOver)
        let harness = try ReleaseHarness(mac: mac)
        let executor = harness.executor
        #expect(mac.read(\.cleanupPending) == [true])
        #expect(await executor.owesReleases)
        #expect(try await harness.move("op-1").code == .cleanupPending)
        #expect(await executor.nextCleanupRetry(at: mac.reading) == mac.reading.monotonic)

        guard case .attempted(.complete)? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("restart cleanup did not release")
            return
        }
        #expect(mac.released == Self.leftOver.reversed())
        #expect(mac.posted.isEmpty)
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(mac.read(\.cleanupPending).last == false)
        #expect(await executor.nextCleanupRetry(at: mac.reading) == nil)
        #expect(try await harness.move("op-2").result != nil)
    }

    @Test("restart cleanup waits for authorization, however late it comes")
    func restartWhileLocked() async throws {
        let mac = FakeMac()
        try mac.leaveInLedger(Self.leftOver)
        mac.setState([.locked])
        let harness = try ReleaseHarness(mac: mac)
        let executor = harness.executor
        guard case .attempted(.deferred([.locked]))? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("restart cleanup ran while locked")
            return
        }
        for _ in 0..<5 {
            mac.advance(byMilliseconds: 60_000)
            guard case .attempted(.deferred)? = await executor.retryCleanup(now: mac.reading) else {
                Issue.record("no retry a minute later")
                return
            }
        }
        #expect(mac.released.isEmpty)
        #expect(mac.ledgerOnDisk == Self.leftOver)

        mac.setState([.disarmed])
        guard case .attempted(.complete)? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("not released once unlocked")
            return
        }
        #expect(mac.released == Self.leftOver.reversed())
    }

    @Test("a crash during cleanup leaves the rest in the ledger, and the next run finishes it")
    func crashDuringCleanup() async throws {
        let faults = ReleaseFaults()
        let mac = HeldChord.mac(abortingWith: [.locked])
        let first = try ReleaseHarness(mac: mac, faults: faults)
        #expect(await first.executor.perform(try first.keyboard(HeldChord.action)).code == .locked)
        #expect(mac.ledgerOnDisk == HeldChord.pressed)

        // The clear of k lands; the process dies writing the clear of shift, after posting its release.
        faults.arm { $0.crashAtWrite = 2 }
        mac.setState([])
        _ = await first.executor.retryCleanup(now: mac.reading)
        #expect(faults.crashed)
        #expect(mac.released == [.named(.k), .modifierKey(.shift)])
        #expect(mac.ledgerOnDisk == Array(HeldChord.pressed.prefix(3)))
        #expect(mac.heldDown == Set(HeldChord.pressed.prefix(2)))

        let second = try first.restarted()
        #expect(await second.executor.owesReleases)
        guard case .attempted(.complete)? = await second.executor.retryCleanup(now: mac.reading) else {
            Issue.record("the next run did not finish cleanup")
            return
        }
        // shift's release went out before the crash and again from the ledger: an extra key-up.
        #expect(mac.released == [.named(.k), .modifierKey(.shift)] + HeldChord.released.dropFirst())
        #expect(mac.heldDown.isEmpty)
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(await second.executor.owesReleases == false)
    }

    @Test(
        "a ledger that cannot be written refuses effects with internal_error and never posts a release twice",
        arguments: [1, 3])
    func clearsFail(failingRetries: Int) async throws {
        let faults = ReleaseFaults()
        let mac = HeldChord.mac(abortingWith: [.locked])
        let harness = try ReleaseHarness(mac: mac, faults: faults)
        let executor = harness.executor
        #expect(await executor.perform(try harness.keyboard(HeldChord.action)).code == .locked)

        // Each failing retry makes one write attempt: the clear of the newest entry.
        faults.arm { $0.failingWrites = Set(1...failingRetries) }
        mac.setState([])
        guard case .attempted(.clearFailed)? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("the failed clear was not reported")
            return
        }
        #expect(mac.released == HeldChord.released)
        #expect(mac.heldDown.isEmpty)
        #expect(mac.ledgerOnDisk == HeldChord.pressed)
        #expect(await executor.storesAvailable == false)
        #expect(await executor.owesReleases)
        #expect(mac.read(\.cleanupPending).last == true)
        #expect(try await harness.move("op-2").code == .internalError)

        for _ in 1..<failingRetries {
            mac.advance(byMilliseconds: 1000)
            guard case .attempted(.clearFailed)? = await executor.retryCleanup(now: mac.reading) else {
                Issue.record("a clear that kept failing was not reported")
                return
            }
            #expect(try await harness.move("op-2").code == .internalError)
        }
        mac.advance(byMilliseconds: 1000)
        guard case .attempted(.complete)? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("the entries were not cleared once the disk took writes")
            return
        }
        #expect(mac.released == HeldChord.released, "a release was posted again")
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(await executor.storesAvailable)
        #expect(mac.read(\.cleanupPending).last == false)
        #expect(try await harness.move("op-3").result != nil)
    }

    @Test("a ledger write that fails during an operation fails it; its releases go out once and are cleared later")
    func ledgerFailsMidOperation() async throws {
        let faults = ReleaseFaults()
        let mac = FakeMac()
        let harness = try ReleaseHarness(mac: mac, faults: faults)
        let executor = harness.executor
        // The chord's fourth write, the entry for k, fails: control, option and shift are down.
        faults.arm { $0.failingWrites = [4] }
        let answer = await executor.perform(try harness.keyboard(HeldChord.action))
        #expect(answer.code == .internalError)
        #expect(answer.operation == OperationView(status: .failed, eventsPosted: 3))
        #expect(mac.released == Array(HeldChord.pressed.prefix(3).reversed()))
        #expect(mac.heldDown.isEmpty)
        #expect(mac.ledgerOnDisk == Array(HeldChord.pressed.prefix(3)))
        #expect(await executor.storesAvailable == false)
        #expect(await executor.owesReleases)

        mac.advance(byMilliseconds: 1000)
        guard case .attempted(.complete)? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("the entries were not cleared")
            return
        }
        #expect(mac.released == Array(HeldChord.pressed.prefix(3).reversed()), "a release was posted again")
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(await executor.storesAvailable)
        #expect(try await harness.move("op-2").result != nil)
    }
}
