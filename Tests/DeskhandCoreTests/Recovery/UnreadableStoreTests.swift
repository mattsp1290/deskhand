import DeskhandCore
import Foundation
import Testing

@Suite("Recovery: stores read again without a call", .timeLimit(.minutes(1)))
struct UnreadableStoreTests {
    static let left: [HeldInput] = [.modifierKey(.shift), .button(.left)]

    @Test("a ledger unreadable at start reports cleanup_pending; once repaired, the retries release what it holds")
    func ledgerRepairedWhileRunning() async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveInLedger(Self.left)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.ledgerPath)
            let started = await rig.start()
            let executor = started.executor
            guard case .ledgerUnreadable = started.report.cleanup else {
                Issue.record("\(started.report)")
                return
            }
            #expect(started.report.effectRefusal == .internalError)
            #expect(rig.mac.read(\.cleanupPending).last == true)
            #expect(!rig.mac.read(\.cleanupPending).contains(false))

            rig.makeReady()
            let watchdog = Watchdog(
                owner: MacOwner(mac: rig.mac), executor: executor, activity: StaticActivity(),
                scheduler: ManualScheduler())
            _ = await watchdog.evaluate()
            let triedAt = rig.mac.reading.monotonic
            #expect(await executor.nextCleanupRetry(at: rig.mac.reading) == triedAt.advanced(by: .seconds(1)))
            rig.mac.advance(byMilliseconds: 1000)
            _ = await watchdog.evaluate()
            #expect(rig.mac.released.isEmpty)
            #expect(await executor.storesAvailable == false)
            #expect(await executor.owesReleases)

            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rig.ledgerPath)
            rig.mac.advance(byMilliseconds: 999)
            _ = await watchdog.evaluate()
            #expect(rig.mac.released.isEmpty, "retried before a second had passed")
            rig.mac.advance(byMilliseconds: 1)
            _ = await watchdog.evaluate()
            #expect(rig.mac.released == Self.left.reversed())
            #expect(try rig.ledgerOnDisk().isEmpty)
            #expect(await executor.storesAvailable)
            #expect(await executor.owesReleases == false)
            #expect(rig.mac.read(\.cleanupPending).last == false)
            #expect(await executor.nextCleanupRetry(at: rig.mac.reading) == nil)
            #expect(try await rig.move(on: executor, operation: "op-1").result != nil)
        }
    }

    @Test("a ledger write that failed on an empty ledger is read again at once, and the next effect is admitted")
    func failedPressOnAnEmptyLedger() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        mac.change { $0.failLedgerWrites = true }
        let first = await harness.executor.perform(try harness.keyboard(["type": "press", "key": "k"]))
        #expect(first.code == .internalError)
        #expect(mac.posted.isEmpty)
        #expect(mac.read(\.cleanupPending).last == true, "a ledger that may hold an entry was reported empty")

        mac.change { $0.failLedgerWrites = false }
        let watchdog = Watchdog(
            owner: MacOwner(mac: mac), executor: harness.executor, activity: StaticActivity(),
            scheduler: ManualScheduler())
        _ = await watchdog.evaluate()
        #expect(await harness.executor.storesAvailable)
        #expect(mac.read(\.cleanupPending).last == false)
        let second = await harness.executor.perform(
            try harness.keyboard(["type": "press", "key": "k"], operation: "op-2"))
        #expect(second.result != nil)
    }

    @Test("a record file unreadable at start is loaded again by the retries once repaired")
    func recordsRepairedWhileRunning() async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveRecords(executing: [RecoveryTests.executing: 3])
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.journalPath)
            let started = await rig.start()
            let executor = started.executor
            #expect(started.report.effectRefusal == .internalError)
            #expect(await executor.owesReleases == false, "no held input is owed with the ledger read and empty")
            rig.makeReady()
            let watchdog = Watchdog(
                owner: MacOwner(mac: rig.mac), executor: executor, activity: StaticActivity(),
                scheduler: ManualScheduler())
            _ = await watchdog.evaluate()
            #expect(await executor.storesAvailable == false)
            let retry = rig.mac.reading.monotonic.advanced(by: .seconds(1))
            #expect(await executor.nextCleanupRetry(at: rig.mac.reading) == retry, "a failed load is retried at once")

            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rig.journalPath)
            rig.mac.advance(byMilliseconds: 1000)
            _ = await watchdog.evaluate()
            #expect(await executor.storesAvailable)
            #expect(await executor.nextCleanupRetry(at: rig.mac.reading) == nil)
            let view = try await executor.operationStatus(for: RecoveryTests.executing)
            #expect(view == .found(OperationView(status: .abortedByRestart, eventsPosted: 3)))
            #expect(try await rig.move(on: executor, operation: "op-1").result != nil)
        }
    }
}
