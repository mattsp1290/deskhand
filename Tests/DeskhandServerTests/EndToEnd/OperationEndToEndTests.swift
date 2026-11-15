import DeskhandCore
import Testing

@testable import DeskhandServer

@Suite("end to end: operations", .timeLimit(.minutes(2)))
struct OperationEndToEndTests {
    static let terminal = ToolFixture.app("com.apple.Terminal", "Terminal")

    @Test("a completed call reports what deskhand measured; a repeat returns it, a conflicting payload does not")
    func repeatAndConflict() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let arguments = Wire.click(frame: frame, "op-1")
            let first = try await stack.call("pointer", arguments)
            #expect(first.status == .ok)
            #expect(first.isError == false)
            let result = try #require(first.structuredContent)
            #expect(first.mcp?.contentText == result)
            #expect(result["status"] == "completed")
            #expect(result["replayed"] == false)
            #expect(result["operation_id"] == "op-1")
            #expect(result["frame_id"] == .string(frame))
            #expect(result["events_posted"] == JSONValue(stack.desk.posted.count))
            #expect(result["measured"]?["frontmost_app"]?["bundle_id"] == "com.apple.TextEdit")
            #expect(result["measured"]?["window_title"] == "notes.txt")
            let posted = stack.desk.posted.count

            let repeated = try await stack.call("pointer", arguments)
            var expected = try #require(result.objectValue)
            expected["replayed"] = true
            #expect(repeated.isError == false)
            #expect(repeated.structuredContent == .object(expected))

            var changed = arguments
            changed["action"] = ["type": "click", "x": 401, "y": 300]
            let conflict = try await stack.call("pointer", changed)
            ContractShape.expectToolError(conflict, "operation_id_conflict")
            #expect(conflict.operation == ["status": "completed", "events_posted": JSONValue(posted)])
            #expect(conflict.structuredContent?["replayed"] == nil)

            #expect(stack.desk.posted.count == posted)
            #expect(try await stack.lookUp("op-1") == ["status": "completed", "events_posted": JSONValue(posted)])
            let kinds = await stack.entries.map(\.kind)
            #expect(kinds.filter { $0 == .intent }.count == 1)
            #expect(kinds.filter { $0 == .outcome }.count == 1)
        }
    }

    @Test(
        "stale_frame names the first reason that holds, and nothing is posted",
        arguments: ["unknown", "display_changed", "not_latest", "too_old", "frontmost_changed", "pixels_changed"])
    func staleFrame(_ reason: String) async throws {
        try await DeskhandStack.with { stack in
            var frame = try await stack.ready()
            var keyboard = false
            switch reason {
            case "unknown": frame = Wire.unknownFrame
            case "display_changed": stack.platform.displays.reconfigure()
            case "not_latest": _ = try await stack.screenshot()
            case "too_old": stack.clock.advance(byMilliseconds: Int64(Limits().frameMaxAgeMs) + 1)
            case "frontmost_changed":
                keyboard = true
                stack.desk.change { $0.frontmost = ToolFixture.notes }
            default: stack.desk.change { $0.patch = .changed }
            }
            let response =
                keyboard
                ? try await stack.call("keyboard", Wire.type("hi", frame: frame, "op-1"))
                : try await stack.call("pointer", Wire.click(frame: frame, "op-1"))
            ContractShape.expectToolError(response, "stale_frame")
            #expect(response.structuredContent?["details"]?["reason"] == .string(reason))
            if reason == "pixels_changed" { #expect(response.structuredContent?["details"]?["point_index"] == 0) }
            #expect(response.operation == nil)
            #expect(stack.desk.posted.isEmpty)
            #expect(await stack.refusalCodes == [.staleFrame])
        }
    }

    @Test("denied_app by the policy and by permitted_apps, with what deskhand measured")
    func deniedApp() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let narrowed = try await stack.call(
                "pointer", Wire.click(frame: frame, "op-1", permittedApps: ["com.apple.Notes"]))
            ContractShape.expectToolError(narrowed, "denied_app")
            #expect(narrowed.structuredContent?["details"]?["denied_by"] == "permitted_apps")

            stack.desk.change { $0.frontmost = Self.terminal }
            let denied = try await stack.call("pointer", Wire.click(frame: frame, "op-2"))
            ContractShape.expectToolError(denied, "denied_app")
            #expect(denied.structuredContent?["details"]?["denied_by"] == "policy")
            #expect(denied.structuredContent?["measured"]?["frontmost_app"]?["bundle_id"] == "com.apple.Terminal")
            #expect(denied.operation == nil)
            #expect(stack.desk.posted.isEmpty)
            #expect(await stack.refusalCodes == [.deniedApp, .deniedApp])
        }
    }

    @Test("while an operation executes: busy for other calls, in progress or conflict for its own key; reads answer")
    func busyWhileExecuting() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let (entered, proceed) = (Latch(), Latch())
            stack.desk.change {
                $0.onSleep = {
                    entered.open()
                    await proceed.wait()
                }
            }
            let arguments = Wire.press("a", holdMs: 1000, frame: frame, "op-1")
            let first = Task { try await stack.call("keyboard", arguments) }
            await entered.wait()

            let executing: JSONValue = ["status": "executing", "events_posted": 1]
            try await stack.session { session in
                let other = await session.call("keyboard", Wire.type("hi", frame: frame, "op-2"))
                ContractShape.expectToolError(other, "busy")
                #expect(other.operation == nil)
                let otherHolder = await session.call(
                    "pointer", Wire.click(frame: frame, "op-1", holder: Wire.otherHolder))
                ContractShape.expectToolError(otherHolder, "busy")

                let same = await session.call("keyboard", arguments)
                ContractShape.expectToolError(same, "operation_in_progress")
                #expect(same.operation == executing)
                var changed = arguments
                changed["action"] = ["type": "press", "key": "b", "hold_ms": 1000]
                let conflict = await session.call("keyboard", changed)
                ContractShape.expectToolError(conflict, "operation_id_conflict")
                #expect(conflict.operation == executing)

                let lookup = await session.call(
                    "status", ["operation": ["holder_id": .string(Wire.holder), "operation_id": "op-1"]])
                #expect(lookup.structuredContent?["operation"] == executing)
                #expect(await session.call("screenshot", ["holder_id": .string(Wire.holder)]).isError == false)
                let renew = await session.call(
                    "lease", ["op": "renew", "holder_id": .string(Wire.holder), "ttl_ms": 120_000])
                #expect(renew.structuredContent?["lease_result"]?["outcome"] == "renewed")
            }
            proceed.open()

            let result = try await first.value
            #expect(result.structuredContent?["status"] == "completed")
            #expect(result.structuredContent?["events_posted"] == 2)
            #expect(stack.desk.posted.count == 2)
        }
    }

    @Test("a caller that hangs up mid-operation aborts it, its input is released, and the repeat returns cancelled")
    func cancelOnDisconnect() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let entered = Latch()
            stack.desk.change {
                $0.onSleep = {
                    entered.open()
                    await waitForHangUp()
                }
            }
            let arguments = Wire.press("a", holdMs: 2000, frame: frame, "op-1")
            try await TestClient.withConnection(to: stack.address, pki: stack.pki, as: .valid) { connection in
                #expect(
                    await connection.send(
                        WireRequest.tool("keyboard", arguments, token: CredentialDirectory.firstToken)))
                await entered.wait()
            }
            #expect(try await eventually { try await stack.lookUp("op-1")?["status"] == "aborted" })
            #expect(stack.desk.released == [.key(try #require(stack.desk.code(for: .a)))])

            let repeated = try await stack.call("keyboard", arguments)
            ContractShape.expectToolError(repeated, "cancelled")
            #expect(repeated.structuredContent?["state"] == "ok")
            #expect(repeated.structuredContent?["current_state"] == "ok")
            #expect(repeated.operation == ["status": "aborted", "events_posted": 1])
            #expect(stack.desk.posted.count == 1)
            guard case .outcome(let outcome)? = await stack.entries.last(where: { $0.kind == .outcome }) else {
                Issue.record("no outcome entry")
                return
            }
            #expect(outcome.outcome.code == .cancelled)
            #expect(outcome.outcome.status == .aborted)
        }
    }

    @Test("rate_limited over the wire, with the time until the oldest counted call leaves the window")
    func rateLimited() async throws {
        try await DeskhandStack.with(.init(limits: Limits(actionsPerMinute: 2))) { stack in
            let frame = try await stack.ready()
            let first = stack.clock.reading.wall
            for operation in ["op-1", "op-2"] {
                let response = try await stack.call("keyboard", Wire.type("hi", frame: frame, operation))
                #expect(response.structuredContent?["status"] == "completed")
            }
            let limited = try await stack.call("keyboard", Wire.type("hi", frame: frame, "op-3"))
            ContractShape.expectToolError(limited, "rate_limited")
            let elapsed = stack.clock.reading.wall.millisecondsSinceEpoch - first.millisecondsSinceEpoch
            #expect(limited.structuredContent?["retry_after_ms"] == JSONValue(ActionCeiling.windowMs - elapsed))
            #expect(limited.operation == nil)
            #expect(try await stack.lookUp("op-3") == .null)
            let status = try await stack.call("status")
            #expect(status.structuredContent?["limits"]?["actions_per_minute"] == 2)
        }
    }

    @Test("operations, frames and the lease are scoped to the holder")
    func holderIsolation() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let arguments = Wire.type("hi", frame: frame, "op-1")
            #expect(try await stack.call("keyboard", arguments).structuredContent?["status"] == "completed")
            let posted = stack.desk.posted.count

            let refusedLease = try await stack.acquire(Wire.otherHolder)
            #expect(refusedLease.isError == false)
            #expect(refusedLease.structuredContent?["lease_result"]?["code"] == "lease_held_by_other")
            #expect(refusedLease.structuredContent?["lease"]?["held_by_caller"] == false)
            let blocked = try await stack.call(
                "keyboard", Wire.type("hi", frame: frame, "op-1", holder: Wire.otherHolder))
            ContractShape.expectToolError(blocked, "lease_held_by_other")
            #expect(blocked.operation == nil)
            #expect(try await stack.lookUp("op-1", holder: Wire.otherHolder) == .null)
            let otherFrame = try await stack.screenshot(Wire.otherHolder)

            _ = try await stack.call("lease", ["op": "release", "holder_id": .string(Wire.holder)])
            let noLease = try await stack.call("keyboard", Wire.type("hi", frame: frame, "op-2"))
            ContractShape.expectToolError(noLease, "lease_not_held")
            #expect(noLease.operation == nil)
            #expect(
                try await stack.acquire(Wire.otherHolder).structuredContent?["lease_result"]?["outcome"] == "acquired")
            let foreignFrame = try await stack.call(
                "keyboard", Wire.type("hi", frame: frame, "op-1", holder: Wire.otherHolder))
            ContractShape.expectToolError(foreignFrame, "stale_frame")
            #expect(foreignFrame.structuredContent?["details"]?["reason"] == "unknown")

            let own = try await stack.call(
                "keyboard", Wire.type("hi", frame: otherFrame, "op-1", holder: Wire.otherHolder))
            #expect(own.structuredContent?["status"] == "completed")
            #expect(own.structuredContent?["replayed"] == false)
            #expect(stack.desk.posted.count == 2 * posted)

            #expect(try await stack.lookUp("op-1") == ["status": "completed", "events_posted": JSONValue(posted)])
            #expect(try await stack.call("keyboard", arguments).structuredContent?["replayed"] == true)
        }
    }
}
