import DeskhandCore
import Testing

@testable import DeskhandServer

@Suite("end to end: codes and state changes", .timeLimit(.minutes(2)))
struct CoverageEndToEndTests {
    static let terminal = ToolFixture.app("com.apple.Terminal", "Terminal")

    @Test("out_of_frame names the target outside the frame, and nothing is posted")
    func outOfFrame() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let response = try await stack.call("pointer", Wire.click(x: 2355, y: 10, frame: frame, "op-1"))
            ContractShape.expectToolError(response, "out_of_frame")
            #expect(response.structuredContent?["details"]?["point_index"] == 0)
            #expect(response.structuredContent?["details"]?["output_pixel_size"] == ["width": 2355, "height": 1522])
            #expect(response.operation == nil)
            #expect(stack.desk.posted.isEmpty)
        }
    }

    @Test("denied_shortcut names the chord, and nothing is posted")
    func deniedShortcut() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let spotlight: JSONValue = ["type": "press", "key": "space", "modifiers": ["command"]]
            let response = try await stack.call(
                "keyboard", Wire.effect(spotlight, frame: frame, "op-1", holder: Wire.holder))
            ContractShape.expectToolError(response, "denied_shortcut")
            #expect(response.structuredContent?["details"] == ["shortcut": "command+space"])
            #expect(response.operation == nil)
            #expect(stack.desk.posted.isEmpty)
            #expect(await stack.refusalCodes == [.deniedShortcut])
        }
    }

    @Test("denied_app for the app under a pointer target carries point_index")
    func deniedAppUnderTarget() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            stack.desk.change { $0.underTarget = Self.terminal }
            let response = try await stack.call("pointer", Wire.click(frame: frame, "op-1"))
            ContractShape.expectToolError(response, "denied_app")
            #expect(response.structuredContent?["details"]?["denied_by"] == "policy")
            #expect(response.structuredContent?["details"]?["point_index"] == 0)
            #expect(response.operation == nil)
            #expect(stack.desk.posted.isEmpty)
        }
    }

    @Test("lease_expired once the holder's lease ran out")
    func leaseExpired() async throws {
        try await DeskhandStack.with { stack in
            try await stack.acquire(ttlMs: 5000)
            let frame = try await stack.screenshot()
            stack.clock.advance(byMilliseconds: 5001)
            let response = try await stack.call("keyboard", Wire.type("hi", frame: frame, "op-1"))
            ContractShape.expectToolError(response, "lease_expired")
            #expect(response.operation == nil)
            #expect(stack.desk.posted.isEmpty)
        }
    }

    @Test("operation_capacity once the principal's records are at the cap")
    func operationCapacity() async throws {
        try await DeskhandStack.with(.init(limits: Limits(operationMaxRecords: 1))) { stack in
            let frame = try await stack.ready()
            let first = try await stack.call("keyboard", Wire.type("hi", frame: frame, "op-1"))
            #expect(first.structuredContent?["status"] == "completed")
            let posted = stack.desk.posted.count

            let response = try await stack.call("keyboard", Wire.type("hi", frame: frame, "op-2"))
            ContractShape.expectToolError(response, "operation_capacity")
            #expect(response.operation == nil)
            #expect(try await stack.lookUp("op-2") == .null)
            #expect(stack.desk.posted.count == posted)
        }
    }

    @Test("image_too_large from the capturer, and from an image over the limit it returned anyway")
    func imageTooLarge() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            stack.platform.capturer.configure { $0.tooLarge = 3_900_000 }
            let refused = try await stack.call("screenshot", ["holder_id": .string(Wire.holder)])
            ContractShape.expectToolError(refused, "image_too_large")
            #expect(refused.structuredContent?["details"] == ["image_bytes": 3_900_000, "max_image_bytes": 3_750_000])

            stack.platform.capturer.configure {
                $0.tooLarge = nil
                $0.imageBytes = ContractConstants.maxImageBytes + 1
            }
            let oversized = try await stack.call("screenshot", ["holder_id": .string(Wire.holder)])
            ContractShape.expectToolError(oversized, "image_too_large")
            #expect(oversized.structuredContent?["details"]?["image_bytes"] == 3_750_001)
            #expect(oversized.mcp?.content.contains { $0["type"] == "image" } == false)

            let click = try await stack.call("pointer", Wire.click(frame: frame, "op-1"))
            #expect(click.structuredContent?["status"] == "completed")
        }
    }

    @Test("internal_error from a capture fault and a display list that cannot be read")
    func internalError() async throws {
        try await DeskhandStack.with { stack in
            stack.platform.capturer.configure { $0.fault = true }
            let capture = try await stack.call("screenshot", ["holder_id": .string(Wire.holder)])
            ContractShape.expectToolError(capture, "internal_error")
            stack.platform.capturer.configure { $0.fault = false }

            stack.platform.displays.failReads()
            let displays = try await stack.call("displays")
            ContractShape.expectToolError(displays, "internal_error")
        }
    }

    @Test("the kill switch during an executing operation aborts it, releases its input, drops the lease and the frames")
    func killSwitchDuringOperation() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let (entered, proceed) = (Latch(), Latch())
            stack.desk.change {
                $0.onSleep = {
                    entered.open()
                    await proceed.wait()
                }
            }
            let arguments = Wire.press("a", holdMs: 2000, frame: frame, "op-1")
            let held = Task { try await stack.call("keyboard", arguments) }
            await entered.wait()
            await stack.hold([.paused])
            proceed.open()

            let aborted = try await held.value
            ContractShape.expectToolError(aborted, "paused")
            #expect(aborted.structuredContent?["replayed"] == false)
            #expect(aborted.operation == ["status": "aborted", "events_posted": 1])
            #expect(stack.desk.released == [.key(try #require(stack.desk.code(for: .a)))])

            let status = try await stack.call("status", ["holder_id": .string(Wire.holder)])
            #expect(status.structuredContent?["state"] == "paused")
            #expect(status.structuredContent?["lease"]?["held_by_caller"] == false)

            await stack.hold([])
            stack.clock.advance(byMilliseconds: Int64(ContractConstants.userActivityLookbackMs))
            await stack.arm()
            let repeated = try await stack.call("keyboard", arguments)
            ContractShape.expectToolError(repeated, "paused")
            #expect(repeated.structuredContent?["replayed"] == true)
            #expect(repeated.structuredContent?["current_state"] == "ok")
            #expect(repeated.operation == aborted.operation)

            try await stack.acquire()
            let stale = try await stack.call("keyboard", Wire.type("hi", frame: frame, "op-2"))
            ContractShape.expectToolError(stale, "stale_frame")
            #expect(stale.structuredContent?["details"]?["reason"] == "unknown")
            #expect(stack.desk.posted.count == 1)
        }
    }

    @Test("arming is refused while an operation executes and just after deskhand posted")
    func onlyAPersonArms() async throws {
        try await DeskhandStack.with { stack in
            let frame = try await stack.ready()
            let armedUntil = try #require(try await Self.armedUntil(stack))

            let (entered, proceed) = (Latch(), Latch())
            stack.desk.change {
                $0.onSleep = {
                    entered.open()
                    await proceed.wait()
                }
            }
            let held = Task { try await stack.call("keyboard", Wire.press("a", holdMs: 1000, frame: frame, "op-1")) }
            await entered.wait()
            #expect(stack.stateOwner.observer.ownInput.operationExecuting)
            await stack.arm()
            #expect(abs(try #require(try await Self.armedUntil(stack)) - armedUntil) <= 5)
            proceed.open()
            #expect(try await held.value.structuredContent?["status"] == "completed")

            await stack.arm()
            #expect(abs(try #require(try await Self.armedUntil(stack)) - armedUntil) <= 5)

            stack.clock.advance(byMilliseconds: Int64(ContractConstants.userActivityLookbackMs))
            await stack.arm()
            #expect(try #require(try await Self.armedUntil(stack)) - armedUntil >= 4000)
        }
    }

    static func armedUntil(_ stack: DeskhandStack) async throws -> Int64? {
        guard let text = try await stack.call("status").structuredContent?["armed_until"]?.stringValue,
            let timestamp = Timestamp(canonical: text)
        else { return nil }
        return timestamp.millisecondsSinceEpoch
    }
}
