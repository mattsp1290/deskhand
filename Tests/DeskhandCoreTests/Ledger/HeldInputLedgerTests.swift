import DeskhandCore
import Testing

@Suite struct HeldInputLedgerTests {
    private let control = HeldInput.modifier(.control)
    private let keyA = HeldInput.key(.a)
    private let left = HeldInput.button(.left)

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func reopened(_ machine: LedgerMachine) throws -> [HeldInput] {
        let ledger = try HeldInputLedger(store: machine.store)
        return ledger.pending()
    }

    /// Presses `inputs` in order through the ledger and posts their downs.
    private func press(_ inputs: [HeldInput], _ ledger: inout HeldInputLedger, on machine: LedgerMachine) throws {
        for input in inputs {
            try ledger.willPress(input)
            try machine.post(.down(input))
        }
    }

    @Test func entriesKeepPressOrderAndSurviveReopening() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA, left], &ledger, on: machine)
        #expect(try reopened(machine) == [control, keyA, left])
        try ledger.didRelease(keyA)
        let pending = ledger.pending()
        #expect(pending == [control, left])
        #expect(try reopened(machine) == [control, left])
    }

    @Test func writesTheCanonicalFormat() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA, left], &ledger, on: machine)
        let expected = #"{"held":[{"modifier":"control"},{"key":"a"},{"button":"left"}],"version":1}"#
        #expect(machine.disk == bytes(expected))
        for input in [left, keyA, control] { try ledger.didRelease(input) }
        #expect(machine.disk == bytes(#"{"held":[],"version":1}"#))
    }

    @Test func everyInputRoundTrips() throws {
        let inputs =
            Key.allCases.map(HeldInput.key) + Modifier.allCases.map(HeldInput.modifier)
            + MouseButton.allCases.map(HeldInput.button)
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press(inputs, &ledger, on: machine)
        #expect(try reopened(machine) == inputs)
    }

    @Test func aStoreNeverWrittenOpensEmpty() throws {
        #expect(try reopened(LedgerMachine()).isEmpty)
    }

    @Test(arguments: [
        "", "not json", "[]", #"{"held":[]}"#, #"{"held":[],"version":2}"#, #"{"held":[],"version":"1"}"#,
        #"{"held":[],"version":1,"extra":true}"#, #"{"held":{},"version":1}"#,
        #"{"held":[{"key":"A"}],"version":1}"#, #"{"held":[{"modifier":"fn"}],"version":1}"#,
        #"{"held":[{"finger":"left"}],"version":1}"#, #"{"held":[{"key":"a","button":"left"}],"version":1}"#,
        #"{"held":[{"key":1}],"version":1}"#, #"{"held":["key a"],"version":1}"#,
        #"{"held":[{"key":"a"},{"key":"a"}],"version":1}"#,
    ])
    func corruptBytesAreRefused(_ text: String) {
        let machine = LedgerMachine(disk: bytes(text))
        do {
            _ = try HeldInputLedger(store: machine.store)
            Issue.record("opened \(text)")
        } catch {
            guard case .corrupt = error else {
                Issue.record("\(error)")
                return
            }
        }
    }

    @Test func aFailedWriteBeforeAPressRecordsNothing() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control], &ledger, on: machine)
        machine.failWrites = true
        do {
            try ledger.willPress(keyA)
            Issue.record("willPress returned after a failed write")
        } catch {
            guard case .writeFailed = error else {
                Issue.record("\(error)")
                return
            }
        }
        let pending = ledger.pending()
        #expect(pending == [control])
        #expect(try reopened(machine) == [control])
    }

    @Test func aFailedClearKeepsTheEntryForCleanup() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA], &ledger, on: machine)
        try machine.post(.up(keyA))
        machine.failWrites = true
        #expect(throws: HeldInputLedgerError.self) { try ledger.didRelease(keyA) }
        var pending = ledger.pending()
        #expect(pending == [control, keyA])

        machine.failWrites = false
        let outcome = ledger.releasePending(authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .complete = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(machine.posted.suffix(3) == [.up(keyA), .up(keyA), .up(control)])
        pending = ledger.pending()
        #expect(pending.isEmpty && machine.held.isEmpty)
    }

    @Test func aRepeatedPressOrAnUnknownReleaseWritesNothing() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA], &ledger, on: machine)
        let writes = machine.writes
        try ledger.willPress(control)
        try ledger.didRelease(left)
        #expect(machine.writes == writes)
        let pending = ledger.pending()
        #expect(pending == [control, keyA])
    }

    @Test func cleanupReleasesNewestFirstAndOnlyEntries() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA, left], &ledger, on: machine)
        let outcome = ledger.releasePending(authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .complete = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(machine.posted.suffix(3) == [.up(left), .up(keyA), .up(control)])
        #expect(machine.posted.count == 6 && machine.held.isEmpty)
        #expect(try reopened(machine).isEmpty)
    }

    @Test func cleanupWaitsWhileDeferred() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA], &ledger, on: machine)
        let writes = machine.writes
        let outcome = ledger.releasePending(
            authorization: { .deferred([.locked, .loginWindow]) }, postRelease: machine.postRelease)
        guard case .deferred(let blockers) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(blockers == [.locked, .loginWindow])
        #expect(machine.posted.count == 2 && machine.writes == writes)
        let pending = ledger.pending()
        #expect(pending == [control, keyA])
    }

    @Test func cleanupStopsWhenAuthorizationEndsPartway() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA, left], &ledger, on: machine)
        var checks = 0
        let outcome = ledger.releasePending(
            authorization: {
                checks += 1
                return checks == 1 ? .authorized : .deferred([.secureInput])
            }, postRelease: machine.postRelease)
        guard case .deferred(let blockers) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(blockers == [.secureInput])
        #expect(machine.posted.last == .up(left) && machine.held == [control, keyA])
        #expect(try reopened(machine) == [control, keyA])
    }

    @Test func cleanupStopsAtAFailedPostAndRetriesLater() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA], &ledger, on: machine)
        machine.failPosts = true
        let failed = ledger.releasePending(authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .postFailed(let input, let error) = failed else {
            Issue.record("\(failed)")
            return
        }
        #expect(input == keyA && error is LedgerFault)
        #expect(try reopened(machine) == [control, keyA])

        machine.failPosts = false
        let retried = ledger.releasePending(authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .complete = retried else {
            Issue.record("\(retried)")
            return
        }
        #expect(machine.held.isEmpty)
    }

    @Test func cleanupPostsEveryReleaseWhenClearsFail() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA, left], &ledger, on: machine)
        machine.failWrites = true
        let outcome = ledger.releasePending(authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .clearFailed(.writeFailed(let error)) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(error is LedgerFault)
        #expect(machine.held.isEmpty)
        let pending = ledger.pending()
        #expect(pending == [control, keyA, left])
        #expect(try reopened(machine) == [control, keyA, left])
    }
}
