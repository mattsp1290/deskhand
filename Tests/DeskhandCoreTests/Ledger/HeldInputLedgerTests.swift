import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct HeldInputLedgerTests {
    private let control = HeldInput.control
    private let keyA = HeldInput.keyA
    private let left = HeldInput.button(.left)

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func reopened(_ machine: LedgerMachine) throws -> [HeldInput] {
        let ledger = try HeldInputLedger(store: machine.store)
        return ledger.pending()
    }

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
        let expected = #"{"held":[{"modifier":59},{"key":0},{"button":"left"}],"version":1}"#
        #expect(machine.disk == bytes(expected))
        for input in [left, keyA, control] { try ledger.didRelease(input) }
        #expect(machine.disk == bytes(#"{"held":[],"version":1}"#))
    }

    @Test func everyKindRoundTripsAcrossTheCodeRange() throws {
        let codes: [UInt16] = [0, 1, 0x3B, 0x7F, 0x80, 0xFF, 0x100, 0xFFFE, 0xFFFF]
        let inputs =
            codes.map { HeldInput.key(PostedKeyCode($0)) } + codes.map { HeldInput.modifier(PostedKeyCode($0)) }
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
        #"{"held":[{"key":"a"}],"version":1}"#, #"{"held":[{"modifier":"shift"}],"version":1}"#,
        #"{"held":[{"key":-1}],"version":1}"#, #"{"held":[{"key":65536}],"version":1}"#,
        #"{"held":[{"modifier":1.5}],"version":1}"#, #"{"held":[{"button":0}],"version":1}"#,
        #"{"held":[{"button":"thumb"}],"version":1}"#, #"{"held":[{"finger":0}],"version":1}"#,
        #"{"held":[{"key":0,"button":"left"}],"version":1}"#, #"{"held":["key 0"],"version":1}"#,
        #"{"held":[{"key":0},{"key":0}],"version":1}"#,
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

    private func expectRefusedPress(
        _ input: HeldInput, _ ledger: inout HeldInputLedger, on machine: LedgerMachine,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let attempts = machine.writeAttempts
        do {
            try ledger.willPress(input)
            Issue.record("willPress(\(input)) returned on an unavailable ledger", sourceLocation: sourceLocation)
        } catch {
            guard case .unavailable = error else {
                Issue.record("\(error)", sourceLocation: sourceLocation)
                return
            }
        }
        #expect(machine.writeAttempts == attempts, sourceLocation: sourceLocation)
    }

    @Test(arguments: WriteFault.allCases)
    func aFailedWriteBeforeAPressRecordsNothingAndMakesTheLedgerUnavailable(_ fault: WriteFault) throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control], &ledger, on: machine)
        machine.writeFault = fault
        do {
            try ledger.willPress(keyA)
            Issue.record("willPress returned after a failed write")
        } catch {
            guard case .writeFailed = error else {
                Issue.record("\(error)")
                return
            }
        }
        machine.writeFault = nil
        let pending = ledger.pending()
        #expect(pending == [control])
        #expect(try reopened(machine) == (fault == .landed ? [control, keyA] : [control]))
        let available = ledger.isAvailable
        #expect(!available)
        expectRefusedPress(keyA, &ledger, on: machine)
        expectRefusedPress(left, &ledger, on: machine)
    }

    @Test func aWriteThatLandsAndThenFailsRefusesTheNextPressUntilReload() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([left], &ledger, on: machine)
        try machine.post(.up(left))
        machine.writeFault = .landed
        #expect(throws: HeldInputLedgerError.self) { try ledger.didRelease(left) }
        machine.writeFault = nil
        #expect(try reopened(machine).isEmpty)
        var pending = ledger.pending()
        #expect(pending == [left])

        expectRefusedPress(left, &ledger, on: machine)
        let attempts = machine.writeAttempts
        do {
            try ledger.didRelease(left)
            Issue.record("didRelease returned on an unavailable ledger")
        } catch {
            guard case .unavailable = error else {
                Issue.record("\(error)")
                return
            }
        }
        #expect(machine.writeAttempts == attempts)

        try ledger.reload()
        pending = ledger.pending()
        let available = ledger.isAvailable
        #expect(available && pending.isEmpty)
        try press([left], &ledger, on: machine)
        #expect(try reopened(machine) == [left])
    }

    @Test func aFailedReloadLeavesTheLedgerAsItWas() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control], &ledger, on: machine)
        machine.writeFault = .lost
        #expect(throws: HeldInputLedgerError.self) { try ledger.willPress(keyA) }
        machine.writeFault = nil
        let healthy = machine.disk
        machine.overwriteDisk(bytes("not json"))
        #expect(throws: HeldInputLedgerError.self) { try ledger.reload() }
        let pending = ledger.pending()
        var available = ledger.isAvailable
        #expect(!available && pending == [control])
        machine.overwriteDisk(healthy)
        try ledger.reload()
        available = ledger.isAvailable
        #expect(available)
    }

    @Test func aFailedClearKeepsTheEntryForCleanup() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA], &ledger, on: machine)
        try machine.post(.up(keyA))
        machine.writeFault = .lost
        #expect(throws: HeldInputLedgerError.self) { try ledger.didRelease(keyA) }
        var pending = ledger.pending()
        #expect(pending == [control, keyA])
        machine.writeFault = nil

        let selected = ledger.pending()
        let unavailable = ledger.releasePending(
            selected, authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .clearFailed(.unavailable) = unavailable else {
            Issue.record("\(unavailable)")
            return
        }
        #expect(machine.posted.suffix(3) == [.up(keyA), .up(keyA), .up(control)])
        #expect(machine.held.isEmpty, "an unavailable ledger still posts every release")
        #expect(try reopened(machine) == [control, keyA], "but clears nothing")

        try ledger.reload()
        let reloadedInputs = ledger.pending()
        let outcome = ledger.releasePending(
            reloadedInputs, authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .complete = outcome else {
            Issue.record("\(outcome)")
            return
        }
        pending = ledger.pending()
        #expect(pending.isEmpty && machine.held.isEmpty)
        #expect(try reopened(machine).isEmpty)
    }

    @Test func cleanupOnAnUnavailableLedgerIsNeverComplete() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        machine.writeFault = .landed
        #expect(throws: HeldInputLedgerError.self) { try ledger.willPress(keyA) }
        machine.writeFault = nil
        var pending = ledger.pending()
        #expect(pending.isEmpty)
        let selected = ledger.pending()
        let outcome = ledger.releasePending(selected, authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .clearFailed(.unavailable) = outcome else {
            Issue.record("\(outcome): the disk still lists \(keyA)")
            return
        }
        try ledger.reload()
        pending = ledger.pending()
        #expect(pending == [keyA])
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

    @Test func aPressWhoseChecksFailIsWithdrawnWithoutARelease() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control], &ledger, on: machine)
        let entry = try ledger.willPress(keyA)
        #expect(entry.input == keyA && entry.isNew)
        #expect(try reopened(machine) == [control, keyA], "written and flushed before the checks")
        try ledger.withdraw(entry)
        let pending = ledger.pending()
        #expect(pending == [control])
        #expect(try reopened(machine) == [control])
        #expect(machine.posted == [.down(control)], "no release for a down that was never posted")
    }

    @Test func withdrawingAPressThatFoundItsEntryKeepsTheEntry() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([keyA], &ledger, on: machine)
        let writes = machine.writes
        let again = try ledger.willPress(keyA)
        #expect(!again.isNew)
        try ledger.withdraw(again)
        #expect(machine.writes == writes)
        let pending = ledger.pending()
        #expect(pending == [keyA])
        #expect(try reopened(machine) == [keyA])
    }

    @Test func aFailedWithdrawalKeepsTheEntryForCleanup() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        let entry = try ledger.willPress(left)
        machine.writeFault = .lost
        #expect(throws: HeldInputLedgerError.self) { try ledger.withdraw(entry) }
        machine.writeFault = nil
        let available = ledger.isAvailable
        #expect(!available)
        let pending = ledger.pending()
        #expect(pending == [left])
        #expect(try reopened(machine) == [left])
    }

    @Test func cleanupReleasesNewestFirstAndOnlyEntries() throws {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try press([control, keyA, left], &ledger, on: machine)
        let selected = ledger.pending()
        let outcome = ledger.releasePending(selected, authorization: { .authorized }, postRelease: machine.postRelease)
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
        let selected = ledger.pending()
        let outcome = ledger.releasePending(
            selected, authorization: { .deferred([.locked, .loginWindow]) }, postRelease: machine.postRelease)
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
        let selected = ledger.pending()
        let outcome = ledger.releasePending(
            selected,
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
        let selected = ledger.pending()
        let failed = ledger.releasePending(selected, authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .postFailed(let input, let error) = failed else {
            Issue.record("\(failed)")
            return
        }
        #expect(input == keyA && error is LedgerFault)
        #expect(try reopened(machine) == [control, keyA])

        machine.failPosts = false
        let retryInputs = ledger.pending()
        let retried = ledger.releasePending(
            retryInputs, authorization: { .authorized }, postRelease: machine.postRelease)
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
        machine.writeFault = .lost
        let selected = ledger.pending()
        let outcome = ledger.releasePending(selected, authorization: { .authorized }, postRelease: machine.postRelease)
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
