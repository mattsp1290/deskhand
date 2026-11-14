import DeskhandCore
import Testing

@testable import DeskhandServer

/// States (contract 10) and the conditions that are not states (contract 11) over the wire, with
/// their side effects on the fake Mac and the action log.
@Suite("end to end: states and conditions", .timeLimit(.minutes(2)))
struct StateEndToEndTests {
    /// The states that drop the lease and refuse `acquire` and `renew` with their name (contract 5.2).
    static let leaseDropping: Set<BlockingState> = [.gated, .paused, .disarmed]

    @Test(
        "every tool but status and lease answers with the state's name; status and lease still answer",
        arguments: BlockingState.allCases)
    func eachState(_ state: BlockingState) async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            await stack.hold([state])
            let name = state.rawValue
            try await stack.session { session in
                let calls: [(String, JSONObject?)] = [
                    ("displays", nil), ("screenshot", ["holder_id": .string(Wire.holder)]),
                    ("pointer", Wire.click(frame: frame, "op-p")), ("keyboard", Wire.type("hi", frame: frame, "op-k")),
                ]
                for (tool, arguments) in calls {
                    let response = await session.call(tool, arguments)
                    ContractShape.expectToolError(response, name)
                    #expect(response.operation == nil, "\(tool)")
                    if tool == "pointer" || tool == "keyboard" {
                        #expect(response.structuredContent?["operation_id"] != nil, "\(tool)")
                    }
                }

                let status = await session.call("status")
                #expect(status.isError == false)
                #expect(status.structuredContent?["state"] == .string(name))
                guard case .array(let active)? = status.structuredContent?["active_states"] else {
                    Issue.record("no active_states in \(String(describing: status.structuredContent))")
                    return
                }
                #expect(active.contains(.string(name)))

                let renew = await session.call(
                    "lease", ["op": "renew", "holder_id": .string(Wire.holder), "ttl_ms": 120_000])
                #expect(renew.isError == false)
                if Self.leaseDropping.contains(state) {
                    #expect(renew.structuredContent?["lease_result"]?["outcome"] == "refused")
                    #expect(renew.structuredContent?["lease_result"]?["code"] == .string(name))
                } else {
                    #expect(renew.structuredContent?["lease_result"]?["outcome"] == "renewed")
                }
            }
            #expect(stack.desk.posted.isEmpty)
            let code = try #require(ToolErrorCode(rawValue: name))
            #expect(await stack.refusalCodes == [code, code])
        }
    }

    @Test("user_active: refused before admission, reported by status, and it aborts an executing operation")
    func userActive() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            stack.desk.change { $0.idleMs = 400 }
            let refused = try await stack.call("keyboard", Wire.type("hi", frame: frame, "op-1"))
            ContractShape.expectToolError(refused, "user_active")
            #expect(refused.structuredContent?["details"]?["idle_ms"] == 400)
            #expect(refused.operation == nil)
            #expect(try await stack.reportedConditions().contains("user_active"))
            #expect(stack.desk.posted.isEmpty)

            stack.desk.change { $0.idleMs = 60_000 }
            #expect(!(try await stack.reportedConditions()).contains("user_active"))
            let desk = stack.desk
            desk.change { $0.onSleep = { desk.change { $0.idleMs = 120 } } }
            let aborted = try await stack.call("keyboard", Wire.press("a", holdMs: 2000, frame: frame, "op-2"))
            ContractShape.expectToolError(aborted, "user_active")
            #expect(aborted.structuredContent?["replayed"] == false)
            #expect(aborted.operation?["status"] == "aborted")
            #expect(aborted.structuredContent?["measured"]?["frontmost_app"]?["bundle_id"] == "com.apple.TextEdit")
            #expect(stack.desk.released == [.key(try #require(stack.desk.code(for: .a)))])
        }
    }

    @Test(
        "log_unavailable: nothing is posted while the log cannot commit, and status reports it until an append succeeds"
    )
    func logUnavailable() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            for kind in ActionLogEntryKind.allCases { await stack.log.failEvery(kind, with: .reject(.notCommitted)) }
            let refused = try await stack.call("pointer", Wire.click(frame: frame, "op-1"))
            ContractShape.expectToolError(refused, "log_unavailable")
            #expect(refused.operation == nil)
            #expect(refused.structuredContent?["measured"]?["frontmost_app"]?["bundle_id"] == "com.apple.TextEdit")
            #expect(stack.desk.posted.isEmpty)
            #expect(try await stack.lookUp("op-1") == .null)
            #expect(try await stack.reportedConditions().contains("log_unavailable"))

            for kind in ActionLogEntryKind.allCases { await stack.log.failEvery(kind, with: nil) }
            let admitted = try await stack.call("pointer", Wire.click(frame: frame, "op-1"))
            #expect(admitted.structuredContent?["status"] == "completed")
            #expect(!(try await stack.reportedConditions()).contains("log_unavailable"))
        }
    }

    @Test(
        "a lease released mid-operation aborts it; a release that fails leaves cleanup_pending until the retry posts it"
    )
    func leaseEndAndCleanupPending() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let (entered, proceed) = (Latch(), Latch())
            stack.desk.change {
                $0.onSleep = {
                    entered.open()
                    await proceed.wait()
                }
            }
            let held = Task { try await stack.call("keyboard", Wire.press("a", holdMs: 2000, frame: frame, "op-1")) }
            await entered.wait()
            stack.desk.change { $0.releaseFails = true }
            let release = try await stack.call("lease", ["op": "release", "holder_id": .string(Wire.holder)])
            #expect(release.structuredContent?["lease_result"]?["outcome"] == "released")
            proceed.open()

            let aborted = try await held.value
            ContractShape.expectToolError(aborted, "lease_not_held")
            #expect(aborted.operation?["status"] == "aborted")
            #expect(aborted.operation?["events_posted"] == 1)
            #expect(stack.desk.released.isEmpty)
            #expect(try await stack.reportedConditions().contains("cleanup_pending"))

            try await stack.acquire()
            let next = try await stack.screenshot()
            let pending = try await stack.call("keyboard", Wire.type("hi", frame: next, "op-2"))
            ContractShape.expectToolError(pending, "cleanup_pending")
            #expect(pending.operation == nil)
            #expect(stack.desk.posted.count == 1)

            // The watchdog retries a second after the failed attempt; this time the release goes out.
            stack.desk.change { $0.releaseFails = false }
            stack.clock.advance(byMilliseconds: 1000)
            let key = HeldInput.key(try #require(stack.desk.code(for: .a)))
            #expect(await eventually { stack.desk.released == [key] })
            #expect(try await eventually { !(try await stack.reportedConditions()).contains("cleanup_pending") })
            let admitted = try await stack.call("keyboard", Wire.type("hi", frame: next, "op-2"))
            #expect(admitted.structuredContent?["status"] == "completed")
        }
    }
}
