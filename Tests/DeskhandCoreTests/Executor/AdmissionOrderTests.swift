import DeskhandCore
import Testing

/// Contract 9.5: every refusal step fails at once, and each fix reveals the next step's code, in
/// order, until the call is admitted.
@Suite("Admission: the order of refusals")
struct AdmissionOrderTests {
    /// One refusal step, made to fail, and how to make it pass.
    struct Fault {
        let step: Int
        let code: ToolErrorCode
        /// `denied_app` and `denied_shortcut` count toward the action ceiling (contract 9.5).
        var counts = false
        let fix: (Peel) async throws -> Void
    }

    /// One executor with every fault in place. A call by another principal, admitted and then aborted
    /// by a lock whose releases waited, leaves the ceiling full (one call a minute), input owed in
    /// the ledger and the lease with that other principal.
    final class Peel {
        let harness: Harness
        var mac: FakeMac { harness.mac }
        var operation = "op-1"
        var action: JSONValue
        var frame: String?

        init(action: JSONValue) async throws {
            let loader = FakeStoreLoader()
            loader.configuration = OperationStore.Configuration(retentionMs: 90_000, maxRecordsPerPrincipal: 1)
            let conflicting = OperationKey(
                principal: ExecutorFixture.principal, holderID: ExecutorFixture.holder,
                operationID: OperationID("op-1")!)
            _ = try Sample.admit(
                try Sample.store(loader.disk, at: ExecutorFixture.t0.wall), conflicting, digest: Sample.digest("other"),
                at: ExecutorFixture.t0.wall)
            let mac = FakeMac {
                $0.lease = ExecutorFixture.acquired(ttlMs: 120_000, by: ExecutorFixture.otherPrincipal)
                $0.afterPost[2] = { world, now in world.report = ExecutorFixture.report([.locked], at: now) }
            }
            harness = try Harness(mac: mac, loader: loader, actionsPerMinute: 1)
            self.action = action

            let prior = try harness.keyboard(
                ["type": "press", "key": "a", "modifiers": ["shift"], "hold_ms": 200], operation: "op-prior",
                principal: ExecutorFixture.otherPrincipal)
            let answer = await harness.executor.perform(prior)
            #expect(answer.code == .locked)
            #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 2))
            #expect(mac.ledgerOnDisk == [.modifierKey(.shift), .named(.a)])
            #expect(mac.released.isEmpty)
        }

        func call() throws -> EffectCall {
            switch action["type"] {
            case "press", "type": try harness.keyboard(action, operation: operation, frame: frame)
            default: try harness.pointer(action, operation: operation, frame: frame)
            }
        }

        /// Lets the counted refusal leave the 60 s window, renewing the lease past the jump.
        func clearCeiling() {
            mac.advance(byMilliseconds: 60_001)
            let now = mac.reading
            mac.change { $0.lease = ExecutorFixture.acquired(ttlMs: 120_000, at: now) }
        }

        func run(_ faults: [Fault]) async throws {
            var expected: [ToolErrorCode] = []
            for fault in faults {
                let postedBefore = mac.posted.count
                let answer = await harness.executor.perform(try call())
                #expect(answer.code == fault.code, "step \(fault.step)")
                #expect(mac.posted.count == postedBefore, "step \(fault.step) posted input")
                if operation != "op-1" { #expect(try await harness.status(operation) == .notFound) }
                expected.append(fault.code)
                // The ceiling holds one call a minute and is empty from step 7 on, so a refusal
                // that counts makes the next call rate_limited, and one that wrongly counts makes
                // the next step's code rate_limited.
                if fault.counts {
                    let limited = await harness.executor.perform(try call())
                    #expect(limited.code == .rateLimited, "step \(fault.step) did not count toward the ceiling")
                    expected.append(.rateLimited)
                    clearCeiling()
                }
                try await fault.fix(self)
            }
            let answer = await harness.executor.perform(try call())
            #expect(answer.result != nil, "admitted after every fix: \(String(describing: answer.code))")
            let refusals = await harness.logEntries.compactMap { entry -> ToolErrorCode? in
                guard case .refusal(let refusal) = entry else { return nil }
                return refusal.code
            }
            #expect(refusals == expected)
        }
    }

    /// The steps both tools share: 1 and 4 to 8 (`head`), and 11 (`tail`).
    static func common() -> (head: [Fault], tail: [Fault]) {
        let head = [
            Fault(step: 1, code: .paused) { $0.mac.change { $0.report = ExecutorFixture.okReport } }
        ]
        let middle = [
            Fault(step: 4, code: .operationIDConflict) { $0.operation = "op-2" },
            Fault(step: 5, code: .cleanupPending) { peel in
                guard case .attempted(.complete) = await peel.harness.executor.releaseOwedInput() else {
                    Issue.record("the owed releases were not posted")
                    return
                }
                #expect(peel.mac.released == [.named(.a), .modifierKey(.shift)])
            },
            Fault(step: 6, code: .leaseHeldByOther) { peel in
                let now = peel.mac.reading
                peel.mac.change { $0.lease = ExecutorFixture.acquired(ttlMs: 120_000, at: now) }
            },
            Fault(step: 7, code: .rateLimited) { $0.clearCeiling() },
            // The conflicting record, admitted at the start, leaves the 90 s retention window.
            Fault(step: 8, code: .operationCapacity) { $0.mac.advance(byMilliseconds: 31_000) },
        ]
        let tail = [
            Fault(step: 11, code: .userActive) { $0.mac.change { $0.idleMs = 60_000 } }
        ]
        return (head + middle, tail)
    }

    @Test("pointer: steps 1, 4 to 11, 13, 14 and 15 in order")
    func pointerOrder() async throws {
        let peel = try await Peel(action: ["type": "click", "x": 500, "y": 10])
        peel.frame = "frm_unknownframe0000000"
        peel.mac.change {
            $0.report = ExecutorFixture.report([.paused], at: ExecutorFixture.t0)
            $0.idleMs = 100
            $0.patchVerdict = .changed
            $0.windows = { _ in ObservedWindow(owner: ExecutorFixture.terminal, title: "zsh") }
        }
        await peel.harness.log.failEvery(.intent, with: .reject(.connectionLost))
        let (head, tail) = Self.common()
        try await peel.run(
            head + [
                Fault(step: 9, code: .staleFrame) { $0.frame = nil },
                Fault(step: 10, code: .outOfFrame) { $0.action = ["type": "click", "x": 100, "y": 100] },
            ] + tail + [
                Fault(step: 13, code: .staleFrame) { $0.mac.change { $0.patchVerdict = .unchanged } },
                Fault(step: 14, code: .deniedApp, counts: true) { peel in
                    peel.mac.change {
                        $0.windows = { _ in ObservedWindow(owner: ExecutorFixture.textEdit, title: "notes.txt") }
                    }
                },
                Fault(step: 15, code: .logUnavailable) { await $0.harness.log.failEvery(.intent, with: nil) },
            ])
    }

    @Test("keyboard: steps 1, 2, 4 to 9, 11, 12, 14 and 15 in order")
    func keyboardOrder() async throws {
        let peel = try await Peel(action: ["type": "press", "key": "space", "modifiers": ["command"]])
        peel.mac.change {
            $0.report = ExecutorFixture.report([.paused], at: ExecutorFixture.t0)
            $0.missingKeys = [.space]
            $0.frontmost = ExecutorFixture.notes
            $0.idleMs = 100
            $0.focus = ObservedWindow(owner: ExecutorFixture.terminal, title: "zsh")
        }
        await peel.harness.log.failEvery(.intent, with: .reject(.notCommitted))
        let (head, tail) = Self.common()
        try await peel.run(
            [head[0], Fault(step: 2, code: .invalidArgument) { $0.mac.change { $0.missingKeys = [] } }]
                + head.dropFirst() + [
                    Fault(step: 9, code: .staleFrame) { $0.mac.change { $0.frontmost = ExecutorFixture.textEdit } }
                ] + tail + [
                    Fault(step: 12, code: .deniedShortcut, counts: true) {
                        $0.action = ["type": "press", "key": "space"]
                    },
                    Fault(step: 14, code: .deniedApp, counts: true) { peel in
                        peel.mac.change {
                            $0.focus = ObservedWindow(owner: ExecutorFixture.textEdit, title: "notes.txt")
                        }
                    },
                    Fault(step: 15, code: .logUnavailable) { await $0.harness.log.failEvery(.intent, with: nil) },
                ])
    }
}
