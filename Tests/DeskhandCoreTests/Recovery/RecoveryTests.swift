import DeskhandCore
import Foundation
import Testing

/// A start after a crash or a stop, on real files (contract 10.1, 11.2, 12.7 to 12.9).
@Suite("Recovery: restart", .timeLimit(.minutes(1)))
struct RecoveryTests {
    static let accepted = Sample.key("op-accepted")
    static let executing = Sample.key("op-executing")
    static let completed = Sample.key("op-completed")
    /// In press order.
    static let left: [HeldInput] = [.modifierKey(.command), .modifierKey(.shift), .button(.left), .named(.a)]

    @Test("an executing record becomes aborted_by_restart with its count, an accepted one failed_before_execution")
    func restartRules() async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveRecords(
                accepted: [Self.accepted], executing: [Self.executing: 3], completed: [Self.completed])
            let started = await rig.start()
            let records = started.report.operationRecords
            #expect(records.restarted == [Self.accepted: .failedBeforeExecution, Self.executing: .abortedByRestart])
            #expect(records.count(of: .failedBeforeExecution) == 1)
            #expect(records.count(of: .abortedByRestart) == 1)
            #expect(started.report.effectRefusal == nil)

            let executor = started.executor
            let executingView = try await executor.operationStatus(for: Self.executing)
            let acceptedView = try await executor.operationStatus(for: Self.accepted)
            let completedView = try await executor.operationStatus(for: Self.completed)
            #expect(executingView == .found(OperationView(status: .abortedByRestart, eventsPosted: 3)))
            #expect(acceptedView == .found(OperationView(status: .failedBeforeExecution, eventsPosted: 0)))
            #expect(completedView == .found(OperationView(status: .completed, eventsPosted: 2)))

            // Written durably: the next load finds nothing left unfinished.
            let now = rig.mac.reading.wall
            let reloaded = try OperationStore(storage: FileOperationStorage(path: rig.journalPath), now: now)
            #expect(reloaded.restartedAtLoad.isEmpty)
            #expect(try reloaded.record(for: Self.executing, now: now)?.view.status == .abortedByRestart)
            #expect(try reloaded.record(for: Self.executing, now: now)?.view.eventsPosted == 3)
            #expect(try reloaded.record(for: Self.accepted, now: now)?.view.status == .failedBeforeExecution)
        }
    }

    @Test(
        "held input left by the last run is released at once, newest first, when cleanup is authorized",
        arguments: [[], [.gated], [.displayAsleep], [.permissionMissing, .permissionStale]] as [Set<BlockingState>])
    func authorizedCleanup(firstReading: Set<BlockingState>) async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveInLedger(Self.left)
            let started = await rig.start(firstReading: firstReading)
            guard case .loaded(let left) = started.report.heldInputLedger else {
                Issue.record("the ledger was not loaded: \(started.report)")
                return
            }
            #expect(left == Self.left)
            guard case .attempted(.complete) = started.report.cleanup else {
                Issue.record("not released at start: \(started.report)")
                return
            }
            #expect(rig.mac.released == Self.left.reversed())
            #expect(rig.mac.posted.isEmpty)
            #expect(try rig.ledgerOnDisk().isEmpty)
            #expect(started.report.effectRefusal == nil)
            #expect(rig.mac.read(\.cleanupPending) == [true, false])
            #expect(await started.executor.owesReleases == false)
        }
    }

    @Test(
        "while cleanup is not authorized the releases wait, cleanup_pending refuses effects, and they go out later",
        arguments: [
            ([.locked], [.locked]), ([.notConsole], [.notConsole]), ([.secureInput], [.secureInput]),
        ] as [(Set<BlockingState>, Set<CleanupBlocker>)])
    func deferredCleanup(firstReading: Set<BlockingState>, blockers: Set<CleanupBlocker>) async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveInLedger(Self.left)
            let started = await rig.start(firstReading: firstReading)
            let executor = started.executor
            guard case .attempted(.deferred(let deferredBy)) = started.report.cleanup else {
                Issue.record("released while blocked: \(started.report)")
                return
            }
            #expect(deferredBy == blockers)
            #expect(started.report.effectRefusal == .cleanupPending)
            #expect(rig.mac.released.isEmpty)
            #expect(try rig.ledgerOnDisk() == Self.left)
            #expect(await executor.owesReleases)
            #expect(rig.mac.read(\.cleanupPending).last == true)

            rig.makeReady()
            #expect(try await rig.move(on: executor, operation: "op-1").code == .cleanupPending)
            guard case .attempted(.complete)? = await executor.retryCleanup(now: rig.mac.reading) else {
                Issue.record("not released once cleanup was authorized")
                return
            }
            #expect(rig.mac.released == Self.left.reversed())
            #expect(try rig.ledgerOnDisk().isEmpty)
            #expect(rig.mac.read(\.cleanupPending).last == false)
            #expect(try await rig.move(on: executor, operation: "op-2").result != nil)
        }
    }

    /// Where the first start dies.
    enum CrashPoint: CaseIterable, CustomStringConvertible {
        /// Writing back the restart rules: the new journal never lands.
        case journalRewrite
        /// At the second release, after the first went out and its entry was cleared.
        case secondRelease
        /// After the first release went out, before the clear of its entry reached the disk.
        case firstClear

        var description: String {
            switch self {
            case .journalRewrite: "journal rewrite"
            case .secondRelease: "second release"
            case .firstClear: "first clear"
            }
        }
    }

    @Test(
        "a start that dies part-way leaves what the next start needs, and the next start converges",
        arguments: CrashPoint.allCases)
    func crashDuringRecovery(point: CrashPoint) async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveRecords(accepted: [Self.accepted], executing: [Self.executing: 3])
            try rig.leaveInLedger(Self.left)
            let journalBefore = try rig.bytes(at: rig.journalPath)
            let failingFlush = ScriptedFlush.failing(.full, with: EIO, at: 0)

            let first =
                switch point {
                case .journalRewrite:
                    await rig.start(
                        records: FileOperationStoreLoader(path: rig.journalPath, flusher: failingFlush),
                        poster: DyingPoster(rig.mac, diesAt: 1))
                case .secondRelease:
                    await rig.start(poster: DyingPoster(rig.mac, diesAt: 2))
                case .firstClear:
                    await rig.start(
                        ledgerStore: FileHeldInputStore(path: rig.ledgerPath, flusher: failingFlush),
                        poster: DyingPoster(rig.mac, diesAt: 2))
                }
            switch point {
            case .journalRewrite:
                #expect(try rig.bytes(at: rig.journalPath) == journalBefore)
                #expect(first.report.effectRefusal == .internalError)
                #expect(try rig.ledgerOnDisk() == Self.left)
            case .secondRelease:
                #expect(rig.mac.released == [Self.left.last!])
                #expect(try rig.ledgerOnDisk() == Array(Self.left.dropLast()))
            case .firstClear:
                #expect(rig.mac.released == [Self.left.last!])
                #expect(try rig.ledgerOnDisk() == Self.left)
            }

            let second = await rig.start()
            #expect(second.report.effectRefusal == nil)
            guard case .attempted(.complete) = second.report.cleanup else {
                Issue.record("the second start did not finish cleanup: \(second.report)")
                return
            }
            // A release whose clear never landed goes out again: an extra key-up does no harm.
            let expected = (point == .firstClear ? [Self.left.last!] : []) + Self.left.reversed()
            #expect(rig.mac.released == expected)
            #expect(try rig.ledgerOnDisk().isEmpty)
            let executingView = try await second.executor.operationStatus(for: Self.executing)
            let acceptedView = try await second.executor.operationStatus(for: Self.accepted)
            #expect(executingView == .found(OperationView(status: .abortedByRestart, eventsPosted: 3)))
            #expect(acceptedView == .found(OperationView(status: .failedBeforeExecution, eventsPosted: 0)))
        }
    }

    /// A store that cannot be loaded.
    enum StoreFault: CaseIterable, CustomStringConvertible {
        case corruptJournal, journalTooOpen, journalWrongOwner
        case corruptLedger, ledgerTooOpen, ledgerWrongOwner

        var description: String {
            switch self {
            case .corruptJournal: "corrupt journal"
            case .journalTooOpen: "journal mode 0644"
            case .journalWrongOwner: "journal under another owner"
            case .corruptLedger: "corrupt ledger"
            case .ledgerTooOpen: "ledger mode 0644"
            case .ledgerWrongOwner: "ledger under another owner"
            }
        }

        var hitsJournal: Bool { [.corruptJournal, .journalTooOpen, .journalWrongOwner].contains(self) }

        func matches(_ report: RecoveryReport) -> Bool {
            switch (self, report.operationRecords, report.heldInputLedger) {
            case (.corruptJournal, .unavailable(.corrupt(line: 1, _)), .loaded): true
            case (.journalTooOpen, .unavailable(.unreadable(.permissionsTooWide(mode: 0o644))), .loaded): true
            case (.journalWrongOwner, .unavailable(.unreadable(.directoryWrongOwner)), .loaded): true
            case (.corruptLedger, .loaded, .unavailable(.corrupt)): true
            case (.ledgerTooOpen, .loaded, .unavailable(.readFailed(let error))):
                error as? StorageError == .permissionsTooWide(mode: 0o644)
            case (.ledgerWrongOwner, .loaded, .unavailable(.readFailed(let error))):
                if case .directoryWrongOwner? = error as? StorageError { true } else { false }
            default: false
            }
        }
    }

    @Test(
        "a store that cannot be loaded fails closed: internal_error, the file kept, the report says why",
        arguments: StoreFault.allCases)
    func failClosed(fault: StoreFault) async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveRecords(executing: [Self.executing: 3])
            try rig.leaveInLedger(Self.left)
            let otherOwner = DurableFile.currentUser &+ 1
            var records: (any OperationStoreLoader)?
            var ledgerStore: (any HeldInputStore & Sendable)?
            switch fault {
            case .corruptJournal:
                try FileOperationStorage(path: rig.journalPath).replace(with: Array("not a journal\n".utf8))
            case .journalTooOpen: try setMode(0o644, of: rig.journalPath)
            case .journalWrongOwner: records = FileOperationStoreLoader(path: rig.journalPath, owner: otherOwner)
            case .corruptLedger: try FileHeldInputStore(path: rig.ledgerPath).replace(with: Array("{}".utf8))
            case .ledgerTooOpen: try setMode(0o644, of: rig.ledgerPath)
            case .ledgerWrongOwner: ledgerStore = FileHeldInputStore(path: rig.ledgerPath, owner: otherOwner)
            }
            let faultyPath = fault.hitsJournal ? rig.journalPath : rig.ledgerPath
            let faultyBefore = FileManager.default.contents(atPath: faultyPath)

            let started = await rig.start(records: records, ledgerStore: ledgerStore)
            let executor = started.executor
            #expect(fault.matches(started.report), "\(started.report)")
            #expect(started.report.effectRefusal == .internalError)
            #expect(await executor.storesAvailable == false)
            #expect(FileManager.default.contents(atPath: faultyPath) == faultyBefore)

            rig.makeReady()
            #expect(try await rig.move(on: executor, operation: "op-1").code == .internalError)
            if fault.hitsJournal {
                await #expect(throws: OperationStoreError.unavailable) {
                    try await executor.operationStatus(for: Self.executing)
                }
                // A release needs no record.
                #expect(rig.mac.released == Self.left.reversed())
            } else {
                let view = try await executor.operationStatus(for: Self.executing)
                #expect(view == .found(OperationView(status: .abortedByRestart, eventsPosted: 3)))
                guard case .nothingOwed = started.report.cleanup else {
                    Issue.record("cleanup ran on a ledger that was not read: \(started.report)")
                    return
                }
                #expect(rig.mac.released.isEmpty)
            }
        }
    }

    @Test("stores that become readable are loaded again without a restart, and the owed releases go out")
    func reloadAfterRepair() async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveRecords(executing: [Self.executing: 3])
            try rig.leaveInLedger(Self.left)
            try setMode(0o644, of: rig.journalPath)
            try setMode(0o644, of: rig.ledgerPath)
            let started = await rig.start()
            let executor = started.executor
            #expect(started.report.effectRefusal == .internalError)
            #expect(rig.mac.released.isEmpty)

            try setMode(0o600, of: rig.journalPath)
            try setMode(0o600, of: rig.ledgerPath)
            #expect(await executor.reloadUnavailableStores())
            #expect(await executor.owesReleases)
            rig.makeReady()
            #expect(try await rig.move(on: executor, operation: "op-1").code == .cleanupPending)
            guard case .attempted(.complete)? = await executor.retryCleanup(now: rig.mac.reading) else {
                Issue.record("the reloaded entries were not released")
                return
            }
            #expect(rig.mac.released == Self.left.reversed())
            let view = try await executor.operationStatus(for: Self.executing)
            #expect(view == .found(OperationView(status: .abortedByRestart, eventsPosted: 3)))
            #expect(try await rig.move(on: executor, operation: "op-2").result != nil)
        }
    }

    @Test("a start has no frame, no lease, is disarmed and not paused, and releases nothing before the first reading")
    func startupWorld() async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveInLedger(Self.left)
            let now = rig.mac.reading
            let started = await rig.start(firstReading: nil)
            let world = started.world
            #expect(world.startedAt == now.wall)
            #expect(world.frames.liveFrameCount == 0)
            #expect(world.frames.supersededFrameCount == 0)
            #expect(world.lease.lease == .none)
            #expect(world.lease.lastEnd == nil)
            #expect(rig.mac.read(\.lease) == world.lease)
            #expect(world.report == .startup)
            let states = world.report.activeStates(at: now).states
            #expect(states.contains(.disarmed))
            #expect(!states.contains(.paused))

            // Nothing read yet means every blocking condition holds (contract 10.1: fail closed).
            guard case .attempted(.deferred(let blockers)) = started.report.cleanup else {
                Issue.record("released before the Mac was read: \(started.report)")
                return
            }
            #expect(blockers == Set(CleanupBlocker.allCases))
            #expect(rig.mac.released.isEmpty)
            #expect(started.report.effectRefusal == .cleanupPending)
        }
    }

    @Test("after a clean stop the records are already final with exact counts; what it could not release goes out")
    func afterCleanStop() async throws {
        try await RecoveryRig.with { rig in
            let now = rig.mac.reading.wall
            let store = try OperationStore(storage: FileOperationStorage(path: rig.journalPath), now: now)
            try store.interrupt(try Sample.admit(store, Self.accepted, at: now), eventsPosted: 0)
            let ticket = try Sample.admit(store, Self.executing, at: now)
            try store.markExecuting(ticket)
            try store.interrupt(ticket, eventsPosted: 5)
            // The stop's releases had to wait for a lock.
            try rig.leaveInLedger(Self.left)

            let started = await rig.start()
            #expect(started.report.operationRecords.restarted.isEmpty)
            let executingView = try await started.executor.operationStatus(for: Self.executing)
            let acceptedView = try await started.executor.operationStatus(for: Self.accepted)
            #expect(executingView == .found(OperationView(status: .abortedByRestart, eventsPosted: 5)))
            #expect(acceptedView == .found(OperationView(status: .failedBeforeExecution, eventsPosted: 0)))
            #expect(rig.mac.released == Self.left.reversed())
            #expect(started.report.effectRefusal == nil)
        }
    }

    @Test("recovering twice gives the same records, an empty ledger and no second release")
    func recoverTwice() async throws {
        try await RecoveryRig.with { rig in
            try rig.leaveRecords(accepted: [Self.accepted], executing: [Self.executing: 3])
            try rig.leaveInLedger(Self.left)
            let first = await rig.start()
            let journal = try rig.journalLines()
            let released = rig.mac.released

            let second = await rig.start()
            #expect(second.report.operationRecords.restarted.isEmpty)
            guard case .nothingOwed = second.report.cleanup else {
                Issue.record("the second start owed releases: \(second.report)")
                return
            }
            #expect(try rig.journalLines() == journal)
            #expect(rig.mac.released == released)
            #expect(try rig.ledgerOnDisk().isEmpty)
            #expect(first.report.effectRefusal == nil)
            #expect(second.report.effectRefusal == nil)
            for key in [Self.accepted, Self.executing] {
                let before = try await first.executor.operationStatus(for: key)
                let after = try await second.executor.operationStatus(for: key)
                #expect(before == after)
            }
        }
    }
}

private func setMode(_ mode: Int, of path: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}
