import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct HeldInputLedgerCrashTests {
    enum NamedBoundary: CaseIterable, Sendable {
        case beforeWrite
        case betweenWriteAndPost
        case afterPost
        case afterUpBeforeClear

        func index(in trace: [LedgerBoundary]) throws -> Int {
            let shift = HeldInput.shift
            let index: Int
            switch self {
            case .beforeWrite: index = try #require(trace.firstIndex(of: .beforePost(.down(shift)))) - 2
            case .betweenWriteAndPost: index = try #require(trace.firstIndex(of: .beforePost(.down(shift))))
            case .afterPost: index = try #require(trace.firstIndex(of: .afterPost(.down(shift))))
            case .afterUpBeforeClear: index = try #require(trace.firstIndex(of: .afterPost(.up(shift)))) + 1
            }
            let expected: LedgerBoundary =
                switch self {
                case .beforeWrite, .afterUpBeforeClear: .beforeWrite
                case .betweenWriteAndPost: .beforePost(.down(shift))
                case .afterPost: .afterPost(.down(shift))
                }
            try #require(trace[index] == expected)
            return index
        }

        var expected: (entries: [HeldInput], held: Set<HeldInput>) {
            switch self {
            case .beforeWrite: ([.control], [.control])
            case .betweenWriteAndPost: ([.control, .shift], [.control])
            case .afterPost:
                ([.control, .shift], [.control, .shift])
            case .afterUpBeforeClear: ([.control, .shift], [.control])
            }
        }
    }

    @discardableResult
    private func recover(_ machine: LedgerMachine, sourceLocation: SourceLocation = #_sourceLocation) throws
        -> [HeldInput]
    {
        let crash = machine.crashedAt.map(String.init(describing:)) ?? "no crash"
        machine.restart()
        var ledger = try HeldInputLedger(store: machine.store)
        let entries = ledger.pending()
        #expect(machine.held.isSubset(of: entries), "missed key-up, crash \(crash)", sourceLocation: sourceLocation)

        let postedBefore = machine.posted.count
        let outcome = ledger.releasePending(authorization: { .authorized }, postRelease: machine.postRelease)
        guard case .complete = outcome else {
            Issue.record("cleanup did not complete: \(outcome), crash \(crash)", sourceLocation: sourceLocation)
            return entries
        }
        let released = Array(machine.posted[postedBefore...])
        #expect(released == entries.reversed().map(LedgerEvent.up), "crash \(crash)", sourceLocation: sourceLocation)
        #expect(machine.held.isEmpty, "still down after cleanup, crash \(crash)", sourceLocation: sourceLocation)
        let reopened = try HeldInputLedger(store: machine.store)
        let left = reopened.pending()
        #expect(left.isEmpty, "entries after cleanup, crash \(crash)", sourceLocation: sourceLocation)
        return entries
    }

    private func crash(_ scenario: LedgerScenario, at index: Int) throws -> LedgerMachine {
        let machine = LedgerMachine(crashAt: index)
        var ledger = try HeldInputLedger(store: machine.store)
        do {
            try scenario.run(&ledger, on: machine)
            Issue.record("\(scenario) ran to the end without crashing at \(index)")
        } catch {}
        return machine
    }

    @Test(arguments: NamedBoundary.allCases)
    func namedBoundary(_ boundary: NamedBoundary) throws {
        let trace = try LedgerScenario.chord.trace()
        let machine = try crash(.chord, at: boundary.index(in: trace))
        #expect(machine.held == boundary.expected.held)
        let entries = try recover(machine)
        #expect(entries == boundary.expected.entries)
    }

    @Test(arguments: LedgerScenario.allCases)
    func crashAtEveryBoundary(_ scenario: LedgerScenario) throws {
        let trace = try scenario.trace()
        let inputs = scenario.operations.flatMap { $0 }
        #expect(trace.count == 8 * inputs.count)
        for index in trace.indices {
            let machine = try crash(scenario, at: index)
            #expect(machine.crashedAt == trace[index])
            let held = machine.held
            let entries = try recover(machine)
            #expect(Set(entries).subtracting(held).count <= 1, "crash at \(index): \(trace[index])")
        }
    }

    @Test(arguments: LedgerScenario.allCases, WriteFault.allCases)
    func aFailedWriteAtEveryWrite(_ scenario: LedgerScenario, _ fault: WriteFault) throws {
        let writes = scenario.operations.flatMap { $0 }.count * 2
        for index in 0..<writes {
            let comment: Comment = "\(fault) at write \(index)"
            let machine = LedgerMachine()
            machine.faultAtWrite = (index, fault)
            var ledger = try HeldInputLedger(store: machine.store)
            try scenario.runCarryingOn(&ledger, on: machine, comment: comment)
            #expect(machine.writeAttempts > index, comment)
            let available = ledger.isAvailable
            #expect(!available, "a failed write leaves the ledger unavailable; \(comment)")
            #expect(machine.held.isEmpty, "still down after the run; \(comment)")
            try recover(machine)
        }
    }

    @Test(arguments: LedgerScenario.allCases)
    func crashDuringCleanup(_ scenario: LedgerScenario) throws {
        let lastDown = try #require(scenario.operations.first?.last)
        let pressed = try #require(scenario.trace().firstIndex(of: .afterPost(.down(lastDown))))
        let entries = try #require(scenario.operations.first)

        let probe = try crash(scenario, at: pressed)
        probe.restart()
        var probeLedger = try HeldInputLedger(store: probe.store)
        let cleanupStart = probe.trace.count
        _ = probeLedger.releasePending(authorization: { .authorized }, postRelease: probe.postRelease)
        let cleanupBoundaries = probe.trace.count - cleanupStart
        #expect(cleanupBoundaries == 4 * entries.count)

        for offset in 0..<cleanupBoundaries {
            let machine = try crash(scenario, at: pressed)
            machine.restart()
            var ledger = try HeldInputLedger(store: machine.store)
            #expect(ledger.pending() == entries)
            machine.crashAt = machine.trace.count + offset
            let outcome = ledger.releasePending(authorization: { .authorized }, postRelease: machine.postRelease)
            if case .complete = outcome { Issue.record("cleanup completed despite a crash at \(offset)") }
            #expect(machine.crashedAt != nil)

            let left = try recover(machine)
            #expect(left == Array(entries.prefix(left.count)), "crash at cleanup boundary \(offset)")
        }
    }
}
