import DeskhandCore
import Testing

@Suite("Release: the release handler", .timeLimit(.minutes(1)))
struct HeldInputReleaserTests {
    private static func ledger(_ entries: [HeldInput], on mac: FakeMac, faults: ReleaseFaults) throws
        -> HeldInputLedger
    {
        try mac.leaveInLedger(entries)
        return try HeldInputLedger(store: FaultyLedgerStore(mac: mac, faults: faults))
    }

    private static func authorization(_ states: Set<BlockingState>, conditions: Set<Condition> = [])
        -> CleanupAuthorization
    {
        CleanupAuthorization(active: ActiveStates(states), conditions: conditions)
    }

    @Test("an operation's inputs are released newest first, each entry cleared only after its release")
    func reverseOrder() throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = try Self.ledger(HeldChord.pressed, on: mac, faults: faults)
        let outcome = HeldInputReleaser().release(
            HeldChord.pressed, from: &ledger, poster: FaultyPoster(mac: mac, faults: faults),
            authorization: { .authorized })
        guard case .complete = outcome else {
            Issue.record("not complete: \(outcome)")
            return
        }
        #expect(mac.released == HeldChord.released)
        #expect(ledger.pending().isEmpty)
        #expect(mac.ledgerOnDisk.isEmpty)
        var onDisk = HeldChord.pressed
        for entry in mac.read(\.trace).drop(while: { if case .released = $0 { false } else { true } }) {
            switch entry {
            case .released(let input):
                #expect(onDisk.last == input, "\(input) released out of order")
            case .ledger(let entries):
                #expect(entries == Array(onDisk.dropLast()), "an entry cleared before its release")
                onDisk = entries
            case .posted(let event): Issue.record("cleanup posted \(event)")
            }
        }
    }

    @Test("another operation's held input is neither posted nor cleared")
    func otherOperationUntouched() throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        let others: [HeldInput] = [.modifierKey(.command), .button(.right)]
        let mine: [HeldInput] = [.modifierKey(.shift), .named(.a)]
        var ledger = try Self.ledger([others[0], mine[0], others[1], mine[1]], on: mac, faults: faults)
        let outcome = HeldInputReleaser().release(
            mine, from: &ledger, poster: FaultyPoster(mac: mac, faults: faults), authorization: { .authorized })
        guard case .complete = outcome else {
            Issue.record("not complete: \(outcome)")
            return
        }
        #expect(mac.released == [.named(.a), .modifierKey(.shift)])
        #expect(ledger.pending() == others)
        #expect(mac.ledgerOnDisk == others)
    }

    @Test("the ledger's order decides, and an input the ledger does not record gets no release")
    func ledgerDecides() throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = try Self.ledger([.modifierKey(.option), .named(.b)], on: mac, faults: faults)
        let asked: [HeldInput] = [.named(.b), .button(.left), .modifierKey(.option), .named(.b)]
        let outcome = HeldInputReleaser().release(
            asked, from: &ledger, poster: FaultyPoster(mac: mac, faults: faults), authorization: { .authorized })
        guard case .complete = outcome else {
            Issue.record("not complete: \(outcome)")
            return
        }
        #expect(mac.released == [.named(.b), .modifierKey(.option)])
        #expect(mac.posted.isEmpty)
    }

    static let blocking: [(Set<BlockingState>, Set<Condition>, Set<CleanupBlocker>)] = [
        ([.locked], [], [.locked]),
        ([.notConsole], [], [.notConsole]),
        ([.notConsole], [.loginWindow], [.notConsole, .loginWindow]),
        ([.secureInput], [], [.secureInput]),
        ([.paused, .disarmed, .locked], [], [.locked]),
        ([.gated, .secureInput, .displayAsleep], [.userActive], [.secureInput]),
    ]

    @Test("any blocking condition defers every release: nothing posted, every entry kept", arguments: blocking)
    func blockersDefer(states: Set<BlockingState>, conditions: Set<Condition>, blockers: Set<CleanupBlocker>) throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = try Self.ledger(HeldChord.pressed, on: mac, faults: faults)
        let outcome = HeldInputReleaser().release(
            HeldChord.pressed, from: &ledger, poster: FaultyPoster(mac: mac, faults: faults),
            authorization: { Self.authorization(states, conditions: conditions) })
        guard case .deferred(let found) = outcome else {
            Issue.record("not deferred: \(outcome)")
            return
        }
        #expect(found == blockers)
        #expect(mac.released.isEmpty)
        #expect(ledger.pending() == HeldChord.pressed)
        #expect(mac.ledgerOnDisk == HeldChord.pressed)
    }

    static let releasing: [(Set<BlockingState>, Set<Condition>)] = [
        ([.gated, .disarmed], []), ([.paused, .disarmed], []), ([.disarmed], []), ([.displayAsleep], []),
        ([.permissionMissing], []), ([.permissionStale], []), ([], [.userActive, .logUnavailable]),
        ([.gated, .paused, .disarmed, .displayAsleep, .permissionMissing, .permissionStale], [.cleanupPending]),
    ]

    @Test(
        "releases go out while gated, paused, disarmed and the states that do not block cleanup",
        arguments: releasing)
    func nonBlockingStates(states: Set<BlockingState>, conditions: Set<Condition>) throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = try Self.ledger(HeldChord.pressed, on: mac, faults: faults)
        let outcome = HeldInputReleaser().release(
            HeldChord.pressed, from: &ledger, poster: FaultyPoster(mac: mac, faults: faults),
            authorization: { Self.authorization(states, conditions: conditions) })
        guard case .complete = outcome else {
            Issue.record("not released: \(outcome)")
            return
        }
        #expect(mac.released == HeldChord.released)
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("authorization is asked before every release: a lock part-way stops the rest")
    func lockPartWay() throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = try Self.ledger(HeldChord.pressed, on: mac, faults: faults)
        let outcome = HeldInputReleaser().release(
            HeldChord.pressed, from: &ledger, poster: FaultyPoster(mac: mac, faults: faults),
            authorization: { mac.released.count < 2 ? .authorized : Self.authorization([.locked]) })
        guard case .deferred([.locked]) = outcome else {
            Issue.record("not deferred by the lock: \(outcome)")
            return
        }
        #expect(mac.released == [.named(.k), .modifierKey(.shift)])
        #expect(mac.ledgerOnDisk == [.modifierKey(.control), .modifierKey(.option)])
    }

    @Test("a release that cannot be posted keeps its entry and every older one")
    func postFailsPartWay() throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = try Self.ledger(HeldChord.pressed, on: mac, faults: faults)
        faults.arm { $0.failingReleases = [2] }
        let poster = FaultyPoster(mac: mac, faults: faults)
        let outcome = HeldInputReleaser().release(
            HeldChord.pressed, from: &ledger, poster: poster, authorization: { .authorized })
        guard case .postFailed(let input, _) = outcome else {
            Issue.record("the failed post was not reported: \(outcome)")
            return
        }
        #expect(input == .modifierKey(.shift))
        #expect(mac.released == [.named(.k)])
        #expect(ledger.pending() == Array(HeldChord.pressed.prefix(3)))
        #expect(mac.ledgerOnDisk == Array(HeldChord.pressed.prefix(3)))
        let available = ledger.isAvailable
        #expect(available)

        let retried = HeldInputReleaser().release(
            HeldChord.pressed, from: &ledger, poster: poster, authorization: { .authorized })
        guard case .complete = retried else {
            Issue.record("the retry did not complete: \(retried)")
            return
        }
        #expect(mac.released == HeldChord.released)
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("a clear that fails still posts the remaining releases and leaves the ledger unavailable")
    func clearFails() throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = try Self.ledger(HeldChord.pressed, on: mac, faults: faults)
        faults.arm { $0.failingWrites = [1] }
        let outcome = HeldInputReleaser().release(
            HeldChord.pressed, from: &ledger, poster: FaultyPoster(mac: mac, faults: faults),
            authorization: { .authorized })
        guard case .clearFailed(.writeFailed) = outcome else {
            Issue.record("the failed clear was not reported: \(outcome)")
            return
        }
        #expect(mac.released == HeldChord.released)
        let available = ledger.isAvailable
        #expect(available == false)
        #expect(ledger.pending() == HeldChord.pressed)
        #expect(mac.ledgerOnDisk == HeldChord.pressed)
    }

    @Test("a later authorization denial takes precedence over a failed clear")
    func clearFailureThenDenial() throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = try Self.ledger(HeldChord.pressed, on: mac, faults: faults)
        faults.arm { $0.failingWrites = [1] }
        let outcome = HeldInputReleaser().release(
            HeldChord.pressed, from: &ledger, poster: FaultyPoster(mac: mac, faults: faults),
            authorization: { mac.released.isEmpty ? .authorized : Self.authorization([.locked]) })
        guard case .deferred([.locked]) = outcome else {
            Issue.record("the later denial was not reported: \(outcome)")
            return
        }
        #expect(mac.released == [.named(.k)])
        #expect(ledger.pending() == HeldChord.pressed)
        #expect(mac.ledgerOnDisk == HeldChord.pressed)
        let available = ledger.isAvailable
        #expect(!available)
    }

    @Test("a later post failure takes precedence over a failed clear")
    func clearFailureThenPostFailure() throws {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = try Self.ledger(HeldChord.pressed, on: mac, faults: faults)
        faults.arm {
            $0.failingWrites = [1]
            $0.failingReleases = [2]
        }
        let outcome = HeldInputReleaser().release(
            HeldChord.pressed, from: &ledger, poster: FaultyPoster(mac: mac, faults: faults),
            authorization: { .authorized })
        guard case .postFailed(let input, let error) = outcome else {
            Issue.record("the later post failure was not reported: \(outcome)")
            return
        }
        #expect(input == .modifierKey(.shift))
        #expect(error is ReleaseFault)
        #expect(mac.released == [.named(.k)])
        #expect(ledger.pending() == HeldChord.pressed)
        #expect(mac.ledgerOnDisk == HeldChord.pressed)
        let available = ledger.isAvailable
        #expect(!available)
    }

    @Test("an empty selection still reports an unavailable ledger without authorizing or posting")
    func emptySelectionUnavailable() {
        let mac = FakeMac()
        let faults = ReleaseFaults()
        var ledger = HeldInputLedger(unreadable: mac.ledgerStore)
        let outcome = HeldInputReleaser().release(
            [], from: &ledger, poster: FaultyPoster(mac: mac, faults: faults),
            authorization: {
                Issue.record("authorization was requested without a selected recorded input")
                return .authorized
            })
        guard case .clearFailed(.unavailable) = outcome else {
            Issue.record("the unavailable ledger was not reported: \(outcome)")
            return
        }
        #expect(mac.read(\.trace).isEmpty)
        #expect(ledger.pending().isEmpty)
        let available = ledger.isAvailable
        #expect(!available)
    }
}
