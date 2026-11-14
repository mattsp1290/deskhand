import DeskhandCore
import Testing

@Suite struct OperationLifecycleTests {
    enum Step: CustomStringConvertible {
        case execute
        case progress(Int)
        case complete(Int)
        case abort(Int)
        case fail(Int)
        case interrupt(Int)

        var description: String {
            switch self {
            case .execute: "execute"
            case .progress(let count): "progress(\(count))"
            case .complete(let count): "complete(\(count))"
            case .abort(let count): "abort(\(count))"
            case .fail(let count): "fail(\(count))"
            case .interrupt(let count): "interrupt(\(count))"
            }
        }

        func run(_ store: OperationStore, _ ticket: OperationTicket) throws(OperationStoreError) {
            switch self {
            case .execute: try store.markExecuting(ticket)
            case .progress(let count): try store.recordProgress(ticket, eventsPosted: count)
            case .complete(let count): _ = try store.finish(ticket, Sample.completed(), eventsPosted: count)
            case .abort(let count): _ = try store.finish(ticket, Sample.aborted(), eventsPosted: count)
            case .fail(let count): _ = try store.finish(ticket, Sample.failed(), eventsPosted: count)
            case .interrupt(let count): try store.interrupt(ticket, eventsPosted: count)
            }
        }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let steps: [Step]
        /// The status and count after every step, or the step that must be refused and the status it
        /// is refused from.
        let outcome: Outcome

        enum Outcome {
            case reaches(OperationStatus, Int)
            case refused(step: Int, from: OperationStatus)
        }

        var testDescription: String { steps.map(\.description).joined(separator: " → ") }
    }

    static let cases: [Case] = [
        Case(steps: [.execute, .complete(3)], outcome: .reaches(.completed, 3)),
        Case(steps: [.execute, .progress(2), .progress(2), .complete(5)], outcome: .reaches(.completed, 5)),
        Case(steps: [.execute, .abort(1)], outcome: .reaches(.aborted, 1)),
        Case(steps: [.execute, .fail(0)], outcome: .reaches(.failed, 0)),
        Case(steps: [.fail(0)], outcome: .reaches(.failed, 0)),
        Case(steps: [.abort(0)], outcome: .reaches(.aborted, 0)),
        Case(steps: [.interrupt(0)], outcome: .reaches(.failedBeforeExecution, 0)),
        Case(steps: [.execute, .progress(2), .interrupt(4)], outcome: .reaches(.abortedByRestart, 4)),
        Case(steps: [.complete(0)], outcome: .refused(step: 0, from: .accepted)),
        Case(steps: [.fail(1)], outcome: .refused(step: 0, from: .accepted)),
        Case(steps: [.progress(1)], outcome: .refused(step: 0, from: .accepted)),
        Case(steps: [.interrupt(1)], outcome: .refused(step: 0, from: .accepted)),
        Case(steps: [.execute, .execute], outcome: .refused(step: 1, from: .executing)),
        Case(steps: [.execute, .progress(-1)], outcome: .refused(step: 1, from: .executing)),
        Case(steps: [.execute, .progress(3), .progress(2)], outcome: .refused(step: 2, from: .executing)),
        Case(steps: [.execute, .progress(3), .complete(2)], outcome: .refused(step: 2, from: .executing)),
        Case(steps: [.execute, .progress(2), .interrupt(1)], outcome: .refused(step: 2, from: .executing)),
        Case(steps: [.execute, .complete(1), .abort(1)], outcome: .refused(step: 2, from: .completed)),
        Case(steps: [.execute, .complete(1), .execute], outcome: .refused(step: 2, from: .completed)),
        Case(steps: [.execute, .abort(1), .progress(2)], outcome: .refused(step: 2, from: .aborted)),
        Case(steps: [.fail(0), .execute], outcome: .refused(step: 1, from: .failed)),
        Case(steps: [.interrupt(0), .execute], outcome: .refused(step: 1, from: .failedBeforeExecution)),
        Case(steps: [.execute, .interrupt(1), .complete(1)], outcome: .refused(step: 2, from: .abortedByRestart)),
    ]

    @Test(arguments: cases)
    func followsTheLifecycle(_ testCase: Case) throws {
        let disk = FakeDisk()
        let store = try Sample.store(disk)
        let key = Sample.key("op-1")
        let ticket = try Sample.admit(store, key)
        for (index, step) in testCase.steps.enumerated() {
            let before = try #require(try store.record(for: key, now: Sample.start))
            do throws(OperationStoreError) {
                try step.run(store, ticket)
            } catch {
                guard case .refused(index, let from) = testCase.outcome else {
                    Issue.record("step \(index) \(step) refused: \(error)")
                    return
                }
                #expect(error == .illegalTransition(key, from: from))
                #expect(try store.record(for: key, now: Sample.start) == before, "a refused step changes nothing")
                #expect(store.isAvailable)
                return
            }
        }
        guard case .reaches(let status, let count) = testCase.outcome else {
            Issue.record("every step was accepted")
            return
        }
        let view = try #require(try store.record(for: key, now: Sample.start)?.view)
        #expect(view == OperationView(status: status, eventsPosted: count))
        if status.isTerminal {
            let reloaded = try Sample.store(disk).record(for: key, now: Sample.start)
            #expect(reloaded?.view == view, "a final record is durable and unchanged by a restart")
        }
    }

    @Test func refusesATicketItDidNotIssue() throws {
        let disk = FakeDisk()
        let ticket = try Sample.admit(try Sample.store(disk), Sample.key("op-1"))
        let other = try Sample.store(FakeDisk())
        #expect(throws: OperationStoreError.unknownOperation(ticket.key)) { try other.markExecuting(ticket) }
    }
}

@Suite struct OperationRepeatTests {
    /// Builds a record of `status` for `key` on `disk` and returns a store loaded afterwards.
    static func store(with status: OperationStatus, key: OperationKey, disk: FakeDisk) throws -> OperationStore {
        let store = try Sample.store(disk)
        let ticket = try Sample.admit(store, key)
        switch status {
        case .accepted, .failedBeforeExecution: break
        case .executing, .abortedByRestart:
            try store.markExecuting(ticket)
            try store.recordProgress(ticket, eventsPosted: 12)
        case .completed:
            try store.markExecuting(ticket)
            _ = try store.finish(ticket, Sample.completed(), eventsPosted: 66)
        case .aborted:
            try store.markExecuting(ticket)
            _ = try store.finish(ticket, Sample.aborted(), eventsPosted: 36)
        case .failed:
            try store.markExecuting(ticket)
            _ = try store.finish(ticket, Sample.failed(), eventsPosted: 2)
        }
        let restarts = status == .failedBeforeExecution || status == .abortedByRestart
        return restarts ? try Sample.store(disk) : store
    }

    /// The table in contract 4.3, every row against the same and a different digest.
    @Test(arguments: OperationStatus.allCases, [true, false])
    func answersARepeatByStatusAndDigest(status: OperationStatus, sameDigest: Bool) throws {
        let key = Sample.key("call_01HZX3M9R1")
        let store = try Self.store(with: status, key: key, disk: FakeDisk())
        let record = try #require(try store.record(for: key, now: Sample.start))
        #expect(record.phase.status == status)
        let digest = sameDigest ? Sample.digest("a") : Sample.digest("b")

        let lookup = try store.lookup(key, digest: digest, now: Sample.start)
        switch (status, sameDigest) {
        case (_, false):
            #expect(lookup == .conflict(record.view))
        case (.accepted, true), (.executing, true):
            #expect(lookup == .inProgress(record.view))
        case (_, true):
            guard case .replay(let replay) = lookup else { throw TestFailure("no replay: \(lookup)") }
            #expect(replay.record == record)
        }

        let admission = try store.admit(Sample.receipt(key), digest: digest, now: Sample.start)
        switch (lookup, admission) {
        case (.conflict(let a), .conflict(let b)), (.inProgress(let a), .inProgress(let b)): #expect(a == b)
        case (.replay(let a), .replay(let b)): #expect(a == b)
        default: Issue.record("admit answered \(admission), lookup \(lookup)")
        }
        #expect(try store.record(for: key, now: Sample.start) == record, "a repeat creates and changes nothing")
        #expect(try store.recordCount(for: Sample.principal, now: Sample.start) == 1)
    }

    @Test func keysRecordsByPrincipalHolderAndOperation() throws {
        let store = try Sample.store(FakeDisk())
        let key = Sample.key("op-1")
        _ = try Sample.admit(store, key)
        for other in [
            Sample.key("op-1", holder: "crew-2"), Sample.key("op-1", principal: Sample.otherPrincipal),
            Sample.key("op-2"),
        ] {
            #expect(try store.lookup(other, digest: Sample.digest("a"), now: Sample.start) == .absent)
            #expect(try store.lookup(other, digest: Sample.digest("b"), now: Sample.start) == .absent)
        }
        #expect(
            try store.lookup(key, digest: Sample.digest("b"), now: Sample.start)
                == .conflict(OperationView(status: .accepted, eventsPosted: 0)))
    }
}

@Suite struct OperationReplayTests {
    @Test func storesTheResultItReturnsAndReplaysIt() throws {
        let store = try Sample.store(FakeDisk())
        let key = Sample.key("call_01HZX3M9R1")
        let ticket = try Sample.admit(store, key)
        try store.markExecuting(ticket)
        let sent = try store.finish(ticket, Sample.completed(), eventsPosted: 66)

        guard case .completed(let result) = sent else { throw TestFailure("not completed: \(sent)") }
        #expect(result.operationID == key.operationID)
        #expect(result.eventsPosted == 66)
        #expect(!result.replayed)

        guard case .replay(let replay) = try store.lookup(key, digest: Sample.digest("a"), now: Sample.start) else {
            throw TestFailure("no replay")
        }
        #expect(!replay.isError)
        var expected = result
        expected.replayed = true
        #expect(replay.structuredContent(currentState: .ok) == expected.jsonValue)
        #expect(replay.structuredContent(currentState: .ok)["current_state"] == nil, "a success gains no state")
    }

    /// Contract 12.5 (0.11): a replayed error keeps the `state` it was stored with and gains
    /// `current_state`, so a state's code still carries that state.
    @Test func replaysAStoredErrorWithItsStoredStateAndTheStateNow() throws {
        let store = try Sample.store(FakeDisk())
        let key = Sample.key("call_01HZX3M9Q5")
        let ticket = try Sample.admit(store, key)
        try store.markExecuting(ticket)
        let sent = try store.finish(ticket, Sample.aborted(.paused), eventsPosted: 5)
        let first = try #require(sent.structuredContent.objectValue)
        #expect(first["state"] == "paused")
        #expect(first["replayed"] == false)
        #expect(first["current_state"] == nil)
        #expect(first["operation"] == ["status": "aborted", "events_posted": 5])
        #expect(first["operation_id"] == .string(key.operationID.rawValue))

        guard case .replay(let replay) = try store.lookup(key, digest: Sample.digest("a"), now: Sample.start) else {
            throw TestFailure("no replay")
        }
        #expect(replay.isError)
        var expected = first
        expected["replayed"] = true
        expected["current_state"] = "ok"
        #expect(replay.structuredContent(currentState: .ok) == .object(expected))
    }

    /// The first result is `keyboard.output.error-secure-input-aborted.json` and its replay is
    /// `keyboard.output.replayed-state-abort.json`, apart from the message, which may change.
    @Test func replaysASecureInputAbortAsTheContractShowsIt() throws {
        let store = try Sample.store(FakeDisk())
        let key = Sample.key("call_01HZX3M9R1")
        let ticket = try Sample.admit(store, key)
        try store.markExecuting(ticket)
        let textEdit = AppRef(bundleID: "com.apple.TextEdit", teamID: nil, name: "TextEdit")
        let measured = Measured(
            frontmostApp: textEdit, targetApp: textEdit, windowTitle: "notes.txt", globalPoint: nil,
            measuredAt: Timestamp(millisecondsSinceEpoch: 1_794_668_544_105))
        let error = ToolError(
            .blocked(.secureInput), message: "Secure input turned on while typing. The rest of the text was not typed.",
            state: .secureInput)
        let sent = try store.finish(ticket, .aborted(error, measured: measured), eventsPosted: 18)
        #expect(
            sent.structuredContent == (try Fixtures.json("examples/keyboard.output.error-secure-input-aborted.json")))

        guard case .replay(let replay) = try store.lookup(key, digest: Sample.digest("a"), now: Sample.start) else {
            throw TestFailure("no replay")
        }
        var example = try #require(Fixtures.json("examples/keyboard.output.replayed-state-abort.json").objectValue)
        var content = try #require(replay.structuredContent(currentState: .ok).objectValue)
        example["message"] = nil
        content["message"] = nil
        #expect(content == example)
    }

    @Test func answersARestartedRecordWithInterrupted() throws {
        let disk = FakeDisk()
        let key = Sample.key("call_01HZX3M9R1")
        let store = try Sample.store(disk)
        let ticket = try Sample.admit(store, key)
        try store.markExecuting(ticket)
        try store.recordProgress(ticket, eventsPosted: 12)

        let restarted = try Sample.store(disk, at: Sample.at(1000))
        guard case .replay(let replay) = try restarted.lookup(key, digest: Sample.digest("a"), now: Sample.at(1000))
        else { throw TestFailure("no replay") }
        #expect(replay.isError)
        #expect(replay.answer == .interrupted(OperationView(status: .abortedByRestart, eventsPosted: 12)))
        var example = try #require(Fixtures.json("examples/keyboard.output.error-interrupted.json").objectValue)
        var content = try #require(replay.structuredContent(currentState: .ok).objectValue)
        #expect(content["message"]?.stringValue?.isEmpty == false)
        example["message"] = nil
        content["message"] = nil
        #expect(content == example)

        // Built when the repeat arrives, so both states are the state at that moment.
        let locked = replay.structuredContent(currentState: .locked)
        #expect(locked["state"] == "locked" && locked["current_state"] == "locked")
    }

    @Test func answersAnAcceptedRecordAfterARestartWithFailedBeforeExecution() throws {
        let disk = FakeDisk()
        let key = Sample.key("op-1")
        _ = try Sample.admit(try Sample.store(disk), key)
        guard
            case .replay(let replay) = try Sample.store(disk).lookup(key, digest: Sample.digest("a"), now: Sample.start)
        else { throw TestFailure("no replay") }
        #expect(replay.answer == .interrupted(OperationView(status: .failedBeforeExecution, eventsPosted: 0)))
        let content = try #require(replay.structuredContent(currentState: .ok).objectValue)
        #expect(content["code"] == "interrupted")
        #expect(content["operation"] == ["status": "failed_before_execution", "events_posted": 0])
        #expect(content["replayed"] == true)
        #expect(content["current_state"] == "ok")
        #expect(content["measured"] == nil)
    }

    /// B11: every admitted error carries `measured` (contract 6.7), whether or not the executor's
    /// `ToolError` had one; a `denied_app` keeps the facts of the check that failed.
    @Test func storesMeasuredOnEveryError() throws {
        let store = try Sample.store(FakeDisk())
        for (name, outcome) in [("aborted", Sample.aborted()), ("failed", Sample.failed())] {
            let ticket = try Sample.admit(store, Sample.key(name))
            try store.markExecuting(ticket)
            let sent = try store.finish(ticket, outcome, eventsPosted: 1)
            #expect(sent.structuredContent["measured"] == Sample.measured.jsonValue, "\(name)")
            #expect(sent.measured == Sample.measured, "\(name)")
            let stored = try store.record(for: Sample.key(name), now: Sample.start)
            guard case .ended(let ending, _)? = stored?.phase else { throw TestFailure("\(name) not ended") }
            #expect(ending.structuredContent["measured"] == Sample.measured.jsonValue, "\(name)")
        }

        let preview = AppRef(bundleID: "com.apple.Preview", teamID: nil, name: "Preview")
        let failedCheck = Measured(
            frontmostApp: Sample.textEdit, targetApp: preview, windowTitle: "scan.pdf",
            globalPoint: GlobalPoint(x: 10, y: 20), measuredAt: Sample.at(30))
        let denied = ToolError(
            .deniedApp(.policy, measured: failedCheck, pointIndex: 2), message: "Preview is not allowed.", state: .ok)
        let ticket = try Sample.admit(store, Sample.key("denied"))
        try store.markExecuting(ticket)
        let sent = try store.finish(ticket, .aborted(denied, measured: Sample.measured), eventsPosted: 4)
        #expect(sent.structuredContent["measured"] == failedCheck.forDeniedApp.jsonValue)
        #expect(sent.measured == failedCheck.forDeniedApp)
    }

    /// A14: the record is keyed by the intent the receipt proves committed.
    @Test func admitsUnderTheKeyOfTheCommittedIntent() throws {
        let store = try Sample.store(FakeDisk())
        let key = Sample.key("op-1", holder: "crew-7", principal: Sample.otherPrincipal)
        let receipt = Sample.receipt(key)
        guard case .new(let ticket) = try store.admit(receipt, digest: Sample.digest("a"), now: Sample.start) else {
            throw TestFailure("not admitted")
        }
        #expect(ticket.key == key)
        #expect(try store.record(for: key, now: Sample.start)?.phase == .accepted)
        #expect(try store.recordCount(for: Sample.otherPrincipal, now: Sample.start) == 1)
        #expect(try store.recordCount(for: Sample.principal, now: Sample.start) == 0)
    }
}

@Suite struct OperationRetentionTests {
    static let configuration = OperationStore.Configuration(retentionMs: Int(Sample.day), maxRecordsPerPrincipal: 3)

    @Test func keepsARecordForTheWholeWindowFromAdmission() throws {
        let store = try Sample.store(FakeDisk(), configuration: Self.configuration)
        let key = Sample.key("op-1")
        let ticket = try Sample.admit(store, key)
        try store.markExecuting(ticket)
        _ = try store.finish(ticket, Sample.completed(), eventsPosted: 1)

        let lastMoment = Sample.at(Sample.day - 1)
        guard case .replay = try store.lookup(key, digest: Sample.digest("a"), now: lastMoment) else {
            throw TestFailure("evicted inside the window")
        }
        let windowEnd = Sample.at(Sample.day)
        #expect(try store.lookup(key, digest: Sample.digest("a"), now: windowEnd) == .absent)
        guard case .new = try store.admit(Sample.receipt(key), digest: Sample.digest("b"), now: windowEnd) else {
            throw TestFailure("an expired operation_id is not judged afresh")
        }
    }

    @Test func neverDropsARecordThatIsStillRunning() throws {
        let store = try Sample.store(FakeDisk(), configuration: Self.configuration)
        let key = Sample.key("op-1")
        try store.markExecuting(try Sample.admit(store, key))
        let lookup = try store.lookup(key, digest: Sample.digest("a"), now: Sample.at(2 * Sample.day))
        #expect(lookup == .inProgress(OperationView(status: .executing, eventsPosted: 0)))
    }

    @Test func capsRecordsPerPrincipalAcrossHolders() throws {
        let store = try Sample.store(FakeDisk(), configuration: Self.configuration)
        let first = Sample.key("op-1", holder: "crew-1")
        _ = try Sample.admit(store, first, at: Sample.at(0))
        _ = try Sample.admit(store, Sample.key("op-2", holder: "crew-1"), at: Sample.at(1000))
        _ = try Sample.admit(store, Sample.key("op-3", holder: "crew-2"), at: Sample.at(2000))
        let now = Sample.at(3000)

        #expect(try !store.hasCapacity(for: Sample.principal, now: now))
        #expect(
            try store.admit(Sample.receipt(Sample.key("op-4", holder: "crew-3")), digest: Sample.digest("a"), now: now)
                == .capacity)
        #expect(try store.recordCount(for: Sample.principal, now: now) == 3, "a refused call leaves no record")
        guard case .inProgress = try store.admit(Sample.receipt(first), digest: Sample.digest("a"), now: now) else {
            throw TestFailure("a repeat is not answered at the cap")
        }
        #expect(try store.hasCapacity(for: Sample.otherPrincipal, now: now))
        _ = try Sample.admit(store, Sample.key("op-4", principal: Sample.otherPrincipal), at: now)
    }

    @Test func freesCapacityWhenTheOldestRecordLeavesTheWindow() throws {
        let disk = FakeDisk()
        let store = try Sample.store(disk, configuration: Self.configuration)
        for (index, name) in ["op-1", "op-2", "op-3"].enumerated() {
            let ticket = try Sample.admit(store, Sample.key(name), at: Sample.at(Int64(index) * Sample.hour))
            try store.markExecuting(ticket)
            _ = try store.finish(ticket, Sample.completed(), eventsPosted: 1)
        }
        let beforeExpiry = Sample.at(Sample.day - 1)
        #expect(
            try store.admit(Sample.receipt(Sample.key("op-4")), digest: Sample.digest("a"), now: beforeExpiry)
                == .capacity)

        let restarted = try Sample.store(disk, at: beforeExpiry, configuration: Self.configuration)
        #expect(try restarted.recordCount(for: Sample.principal, now: beforeExpiry) == 3, "the count carries over")
        #expect(
            try restarted.admit(Sample.receipt(Sample.key("op-4")), digest: Sample.digest("a"), now: beforeExpiry)
                == .capacity)

        _ = try Sample.admit(restarted, Sample.key("op-4"), at: Sample.at(Sample.day))
        #expect(try restarted.recordCount(for: Sample.principal, now: Sample.at(Sample.day)) == 3)
        #expect(
            try restarted.lookup(Sample.key("op-1"), digest: Sample.digest("a"), now: Sample.at(Sample.day)) == .absent)
    }

    @Test func dropsExpiredRecordsFromTheFileAtLoad() throws {
        let disk = FakeDisk()
        let store = try Sample.store(disk, configuration: Self.configuration)
        let ticket = try Sample.admit(store, Sample.key("op-1"))
        try store.markExecuting(ticket)
        _ = try store.finish(ticket, Sample.completed(), eventsPosted: 1)
        _ = try Sample.admit(store, Sample.key("op-2"), at: Sample.at(Sample.hour))

        let later = Sample.at(Sample.day + 1)
        let restarted = try Sample.store(disk, at: later, configuration: Self.configuration)
        #expect(disk.lines.count == 2, "header and op-2 only: \(disk.lines)")
        #expect(try restarted.lookup(Sample.key("op-1"), digest: Sample.digest("a"), now: later) == .absent)
        #expect(try restarted.record(for: Sample.key("op-2"), now: later)?.phase == .failedBeforeExecution)
    }
}

@Suite struct OperationRestartTests {
    @Test func appliesTheRestartRulesDurably() throws {
        let disk = FakeDisk()
        let store = try Sample.store(disk)
        let accepted = Sample.key("accepted")
        let executing = Sample.key("executing")
        let completed = Sample.key("completed")
        _ = try Sample.admit(store, accepted)
        let running = try Sample.admit(store, executing)
        try store.markExecuting(running)
        try store.recordProgress(running, eventsPosted: 7)
        let done = try Sample.admit(store, completed)
        try store.markExecuting(done)
        _ = try store.finish(done, Sample.completed(), eventsPosted: 3)
        let completedRecord = try store.record(for: completed, now: Sample.start)

        let restarted = try Sample.store(disk, at: Sample.at(1000))
        #expect(try restarted.record(for: accepted, now: Sample.at(1000))?.phase == .failedBeforeExecution)
        #expect(try restarted.record(for: executing, now: Sample.at(1000))?.phase == .abortedByRestart(eventsPosted: 7))
        #expect(try restarted.record(for: completed, now: Sample.at(1000)) == completedRecord)
        #expect(!disk.text.contains(#""status":"accepted""#))
        #expect(!disk.text.contains(#""status":"executing""#))
        #expect(disk.durable == disk.visible, "the restart rules are flushed before the store is returned")

        let again = try Sample.store(disk, at: Sample.at(2000))
        for key in [accepted, executing, completed] {
            #expect(
                try again.record(for: key, now: Sample.at(2000)) == restarted.record(for: key, now: Sample.at(1000)))
        }
    }

    @Test func recordsACleanStopWithTheExactCount() throws {
        let disk = FakeDisk()
        let store = try Sample.store(disk)
        let waiting = try Sample.admit(store, Sample.key("waiting"))
        let running = try Sample.admit(store, Sample.key("running"))
        try store.markExecuting(running)
        try store.recordProgress(running, eventsPosted: 2)
        try store.interrupt(running, eventsPosted: 5)
        try store.interrupt(waiting, eventsPosted: 0)

        let restarted = try Sample.store(disk)
        #expect(
            try restarted.record(for: Sample.key("running"), now: Sample.start)?.phase
                == .abortedByRestart(eventsPosted: 5))
        #expect(try restarted.record(for: Sample.key("waiting"), now: Sample.start)?.phase == .failedBeforeExecution)
    }

    @Test func compactsTheJournalWithoutLosingRecords() throws {
        let disk = FakeDisk()
        let configuration = OperationStore.Configuration(compactAfterEntries: 8)
        let store = try Sample.store(disk, configuration: configuration)
        for index in 0..<10 {
            let ticket = try Sample.admit(store, Sample.key("op-\(index)"))
            try store.markExecuting(ticket)
            for _ in 0..<5 { try store.recordProgress(ticket, eventsPosted: 0) }
            _ = try store.finish(ticket, Sample.completed(), eventsPosted: index)
        }
        #expect(disk.lines.count < 1 + 8 * 10, "the journal was rewritten: \(disk.lines.count) lines")
        let restarted = try Sample.store(disk, configuration: configuration)
        for index in 0..<10 {
            let view = try restarted.record(for: Sample.key("op-\(index)"), now: Sample.start)?.view
            #expect(view == OperationView(status: .completed, eventsPosted: index))
        }
    }
}

@Suite struct OperationJournalLoadTests {
    static func journal() throws -> FakeDisk {
        let disk = FakeDisk()
        let store = try Sample.store(disk)
        let ticket = try Sample.admit(store, Sample.key("op-1"))
        try store.markExecuting(ticket)
        _ = try store.finish(ticket, Sample.completed(), eventsPosted: 4)
        return disk
    }

    @Test(arguments: ["{\"entry\":\"fin", "{\"entry\":\"finish\"\u{0}\u{0}\u{0}\n", "\u{0}\u{0}\u{0}\u{0}\n"])
    func dropsATornLastLine(_ tail: String) throws {
        let disk = try Self.journal()
        disk.visible! += Array(tail.utf8)
        let store = try Sample.store(disk)
        #expect(
            try store.record(for: Sample.key("op-1"), now: Sample.start)?.view
                == OperationView(status: .completed, eventsPosted: 4))
        #expect(disk.text.hasSuffix("}\n"), "the reload rewrote the file without the tail")
    }

    @Test func refusesACorruptLineBeforeTheLast() throws {
        let disk = try Self.journal()
        var lines = disk.lines
        lines.insert("not json", at: 2)
        disk.visible = Array((lines.joined(separator: "\n") + "\n").utf8)
        let error = #expect(throws: OperationStoreLoadError.self) { try Sample.store(disk) }
        guard case .corrupt(let line, _) = error else { throw TestFailure("not corrupt: \(String(describing: error))") }
        #expect(line == 3)
    }

    @Test func refusesATransitionTheLifecycleDoesNotAllow() throws {
        let disk = try Self.journal()
        let execute = try #require(disk.lines.first { $0.contains(#""entry":"execute""#) })
        disk.visible! += Array((execute + "\n" + execute + "\n").utf8)
        let error = #expect(throws: OperationStoreLoadError.self) { try Sample.store(disk) }
        guard case .corrupt(let line, _) = error else { throw TestFailure("not corrupt: \(String(describing: error))") }
        #expect(line == disk.lines.count - 1)
    }

    /// A13: a damaged admission time is corruption, wherever the line is, and never a crash.
    @Test(arguments: ["-9223372036854775808", "-1", "253402300800000"], [false, true])
    func refusesAnAdmissionTimeOutOfRange(_ value: String, onTheLastLine: Bool) throws {
        let disk = FakeDisk()
        let store = try Sample.store(disk)
        _ = try Sample.admit(store, Sample.key("op-1"))
        if !onTheLastLine { _ = try Sample.admit(store, Sample.key("op-2")) }
        var lines = disk.lines
        let original = #""admitted_at_ms":\#(Sample.start.millisecondsSinceEpoch)"#
        #expect(lines[1].contains(original))
        lines[1] = lines[1].replacing(original, with: #""admitted_at_ms":\#(value)"#)
        disk.visible = Array((lines.joined(separator: "\n") + "\n").utf8)

        let error = #expect(throws: OperationStoreLoadError.self) { try Sample.store(disk) }
        guard case .corrupt(let line, let reason) = error else {
            throw TestFailure("not corrupt: \(String(describing: error))")
        }
        #expect(line == 2)
        #expect(reason.contains("admitted_at_ms"))
    }

    /// Counts are read with the one integer rule of every reader.
    @Test(arguments: ["1.5", "-1", "9007199254740992", "\"3\""])
    func refusesACountThatIsNotACount(_ value: String) throws {
        let disk = try Self.journal()
        var lines = disk.lines
        let finish = try #require(lines.firstIndex { $0.contains(#""entry":"finish""#) })
        #expect(lines[finish].contains(#""events_posted":4"#))
        lines[finish] = lines[finish].replacing(#""events_posted":4"#, with: #""events_posted":\#(value)"#)
        disk.visible = Array((lines.joined(separator: "\n") + "\n").utf8)

        let error = #expect(throws: OperationStoreLoadError.self) { try Sample.store(disk) }
        guard case .corrupt(let line, let reason) = error else {
            throw TestFailure("not corrupt: \(String(describing: error))")
        }
        #expect(line == finish + 1)
        #expect(reason.contains("events_posted"))
    }

    @Test func acceptsTheEndsOfTheAdmissionRange() throws {
        for milliseconds: Int64 in [0, 253_402_300_799_999] {
            let disk = FakeDisk()
            let store = try Sample.store(disk)
            _ = try Sample.admit(store, Sample.key("op-1"), at: Timestamp(millisecondsSinceEpoch: milliseconds))
            let restarted = try Sample.store(disk, at: Timestamp(millisecondsSinceEpoch: milliseconds))
            #expect(
                try restarted.record(for: Sample.key("op-1"), now: Timestamp(millisecondsSinceEpoch: milliseconds))?
                    .admittedAt.millisecondsSinceEpoch == milliseconds)
        }
    }

    @Test func refusesAFileWithoutTheHeader() {
        let disk = FakeDisk("{\"journal\":\"something-else\",\"version\":1}\n")
        #expect(
            throws: OperationStoreLoadError.corrupt(line: 1, reason: "missing deskhand-operations version 1 header")
        ) {
            try Sample.store(disk)
        }
    }

    @Test func reportsAnUnreadableFile() {
        let storage = FaultyStorage(FakeDisk())
        storage.readError = .permissionsTooWide(mode: 0o644)
        #expect(throws: OperationStoreLoadError.unreadable(.permissionsTooWide(mode: 0o644))) {
            try OperationStore(storage: storage, now: Sample.start)
        }
    }
}
