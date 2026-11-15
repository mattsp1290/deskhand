import DeskhandCore
import Testing

/// Cuts a run at every write boundary, by a write error or by a crash, then restarts on whatever
/// survived and checks the recovered records against what the run was told (contract 12.3, 12.9).
@Suite(.timeLimit(.minutes(1))) struct OperationStoreFaultTests {
    /// What the executor was told, and what it did, for one operation.
    struct Truth {
        var admitAttempted = false
        var admitted = false
        var executeAttempted = false
        var executing = false
        /// Events "posted". The executor posts only after `markExecuting` returned.
        var posted = 0
        var progressed = 0
        var finishAttempted: OperationView?
        var finished: OperationRecord?
    }

    /// One operation of the run: its progress reports, the events it posts in all, and how it ends
    /// (`nil` leaves it where it is when the run stops).
    struct Script {
        let key: OperationKey
        let executes: Bool
        let progress: [Int]
        let total: Int
        let ending: OperationOutcome?
    }

    static let seededDone = Sample.key("seeded-done")
    static let seededRunning = Sample.key("seeded-running")
    static let runAt = Sample.at(1000)
    static let restartAt = Sample.at(2000)

    static let scripts = [
        Script(key: Sample.key("completes"), executes: true, progress: [2], total: 3, ending: Sample.completed()),
        Script(key: Sample.key("aborts"), executes: true, progress: [], total: 1, ending: Sample.aborted()),
        Script(key: Sample.key("left-accepted"), executes: false, progress: [], total: 0, ending: nil),
        Script(key: Sample.key("left-executing"), executes: true, progress: [], total: 1, ending: nil),
    ]

    /// A file from an earlier run: one finished record and one that was executing when it stopped.
    static func seededDisk() throws -> (FakeDisk, OperationRecord) {
        let disk = FakeDisk()
        let store = try Sample.store(disk)
        let done = try Sample.admit(store, seededDone)
        try store.markExecuting(done)
        _ = try store.finish(done, Sample.completed(), eventsPosted: 3)
        let running = try Sample.admit(store, seededRunning)
        try store.markExecuting(running)
        try store.recordProgress(running, eventsPosted: 2)
        disk.crash(.processOnly)
        return (disk, try #require(try store.record(for: seededDone, now: Sample.start)))
    }

    /// Runs every script in turn as the executor would, stopping at the first refusal.
    static func run(on storage: FaultyStorage) -> [OperationKey: Truth] {
        var truths: [OperationKey: Truth] = [:]
        guard let store = try? OperationStore(storage: storage, now: runAt) else { return truths }
        for script in scripts {
            var truth = Truth()
            let carriedOn = run(script, on: store, &truth)
            truths[script.key] = truth
            if !carriedOn { break }
        }
        return truths
    }

    /// `false` when a store call was refused and the run stops.
    private static func run(_ script: Script, on store: OperationStore, _ truth: inout Truth) -> Bool {
        truth.admitAttempted = true
        guard
            case .new(let ticket)? = try? store.admit(
                Sample.receipt(script.key), digest: Sample.digest("a"), now: runAt)
        else {
            expectLatched(store)
            return false
        }
        truth.admitted = true
        guard script.executes else { return true }

        truth.executeAttempted = true
        guard (try? store.markExecuting(ticket)) != nil else {
            giveUp(store, ticket, posted: 0)
            return false
        }
        truth.executing = true
        for count in script.progress {
            truth.posted = count
            guard (try? store.recordProgress(ticket, eventsPosted: count)) != nil else {
                giveUp(store, ticket, posted: truth.posted)
                return false
            }
            truth.progressed = count
        }
        truth.posted = script.total
        guard let ending = script.ending else { return true }
        truth.finishAttempted = OperationView(status: ending.status, eventsPosted: script.total)
        guard (try? store.finish(ticket, ending, eventsPosted: script.total)) != nil else {
            giveUp(store, ticket, posted: truth.posted)
            return false
        }
        truth.finished = try? store.record(for: script.key, now: runAt)
        return true
    }

    /// The executor's answer to a failed record write: end the operation as `failed`. The store
    /// is already unavailable, so this is refused too and nothing more reaches the file.
    static func giveUp(_ store: OperationStore, _ ticket: OperationTicket, posted: Int) {
        #expect(throws: OperationStoreError.unavailable) {
            _ = try store.finish(ticket, Sample.failed(), eventsPosted: posted)
        }
        expectLatched(store)
    }

    static func expectLatched(_ store: OperationStore) {
        #expect(!store.isAvailable)
        #expect(throws: OperationStoreError.unavailable) {
            try store.lookup(Sample.key("anything"), digest: Sample.digest("a"), now: runAt)
        }
    }

    static func check(_ recovered: OperationRecord?, _ truth: Truth, _ comment: Comment) {
        if let recovered {
            #expect(recovered.phase.isFinal, comment)
            #expect(recovered.phase.eventsPosted <= truth.posted, "never more than was posted; \(comment)")
            #expect(recovered.digest == Sample.digest("a"), comment)
            #expect(recovered.admittedAt == runAt, comment)
        }
        if let finished = truth.finished {
            #expect(recovered == finished, "an acknowledged final record survives as it was; \(comment)")
        } else if truth.executing {
            switch recovered?.phase {
            case .abortedByRestart(let count)?:
                #expect(count >= truth.progressed, "an acknowledged count is a lower bound; \(comment)")
            case .ended?:
                #expect(recovered?.view == truth.finishAttempted, comment)
            default:
                Issue.record("executing became \(String(describing: recovered?.phase)); \(comment)")
            }
        } else if truth.admitted {
            let allowed: [OperationPhase] =
                truth.executeAttempted
                ? [.failedBeforeExecution, .abortedByRestart(eventsPosted: 0)] : [.failedBeforeExecution]
            #expect(
                recovered.map { allowed.contains($0.phase) } == true, "\(String(describing: recovered)); \(comment)")
        } else if truth.admitAttempted {
            #expect(recovered == nil || recovered?.phase == .failedBeforeExecution, comment)
        } else {
            #expect(recovered == nil, comment)
        }
    }

    @Test func runsToTheEndWithoutAFault() throws {
        let (disk, _) = try Self.seededDisk()
        let storage = FaultyStorage(disk)
        let truths = Self.run(on: storage)
        #expect(storage.boundaries.count == 24)
        #expect(truths.values.allSatisfy { $0.admitted })
        disk.crash(.unflushed)
        let restarted = try OperationStore(storage: FaultyStorage(disk), now: Self.restartAt)
        let phases = try Self.scripts.map { try restarted.record(for: $0.key, now: Self.restartAt)?.phase.status }
        #expect(phases == [.completed, .aborted, .failedBeforeExecution, .abortedByRestart])
    }

    @Test(arguments: FaultyStorage.Fault.allCases, FakeDisk.Loss.allCases)
    func recoversFromAFaultAtEveryWriteBoundary(fault: FaultyStorage.Fault, loss: FakeDisk.Loss) throws {
        let boundaryCount = 24
        for index in 0..<boundaryCount {
            let (disk, seededDone) = try Self.seededDisk()
            let storage = FaultyStorage(disk, fault: fault, at: index)
            let truths = Self.run(on: storage)
            let comment: Comment = "\(fault) at \(storage.boundaries[index]) (#\(index)), then \(loss)"
            disk.crash(loss)

            let restarted: OperationStore
            do {
                restarted = try OperationStore(storage: FaultyStorage(disk), now: Self.restartAt)
            } catch {
                Issue.record("reload failed: \(error); \(comment)")
                continue
            }
            #expect(disk.durable == disk.visible, "recovery is flushed; \(comment)")
            #expect(try restarted.record(for: Self.seededDone, now: Self.restartAt) == seededDone, comment)
            #expect(
                try restarted.record(for: Self.seededRunning, now: Self.restartAt)?.phase
                    == .abortedByRestart(eventsPosted: 2), comment)
            for script in Self.scripts {
                let recovered = try restarted.record(for: script.key, now: Self.restartAt)
                Self.check(recovered, truths[script.key] ?? Truth(), "\(script.key.operationID): \(comment)")
            }

            let again = try OperationStore(storage: FaultyStorage(disk), now: Self.restartAt)
            for key in Self.scripts.map(\.key) + [Self.seededDone, Self.seededRunning] {
                #expect(
                    try again.record(for: key, now: Self.restartAt) == restarted.record(for: key, now: Self.restartAt),
                    "recovery is stable across a second restart; \(comment)")
            }
        }
    }
}
