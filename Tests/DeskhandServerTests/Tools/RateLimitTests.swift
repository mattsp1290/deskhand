import DeskhandCore
import DeskhandTestSupport
import NIOHTTP1
import Testing

@testable import DeskhandServer

@Suite("rate_limited through the dispatcher")
struct RateLimitTests {
    static let holder = ToolFixture.holder.rawValue
    static let terminal = ToolFixture.app("com.apple.Terminal", "Terminal")

    static func ready(perMinute: Int, holder: String = holder) async throws -> (ToolHarness, String) {
        let harness = try ToolHarness(limits: Limits(actionsPerMinute: perMinute))
        _ = await call(harness, "lease", ["op": "acquire", "holder_id": .string(holder), "ttl_ms": 120_000])
        return (harness, try await frame(harness, holder: holder))
    }

    static func frame(_ harness: ToolHarness, holder: String = holder) async throws -> String {
        let shot = await call(harness, "screenshot", ["holder_id": .string(holder)])
        return try #require(shot.structuredContent?["frame_id"]?.stringValue)
    }

    static func call(_ harness: ToolHarness, _ tool: String, _ arguments: JSONObject) async -> MCPTestResponse {
        await DispatcherWiringTests.call(harness, tool, arguments)
    }

    static func type(_ harness: ToolHarness, frame: String, _ operation: String, holder: String = holder) async
        -> MCPTestResponse
    {
        await call(
            harness, "keyboard",
            [
                "holder_id": .string(holder), "frame_id": .string(frame), "operation_id": .string(operation),
                "action": ["type": "type", "text": "hi"],
            ])
    }

    static func spotlight(_ harness: ToolHarness, frame: String, _ operation: String) async -> MCPTestResponse {
        await call(
            harness, "keyboard",
            [
                "holder_id": .string(holder), "frame_id": .string(frame), "operation_id": .string(operation),
                "action": ["type": "press", "key": "space", "modifiers": ["command"]],
            ])
    }

    static func click(_ harness: ToolHarness, frame: String, _ operation: String) async -> MCPTestResponse {
        await call(
            harness, "pointer",
            [
                "holder_id": .string(holder), "frame_id": .string(frame), "operation_id": .string(operation),
                "action": ["type": "click", "x": 100, "y": 100],
            ])
    }

    static func lookUp(_ harness: ToolHarness, _ operation: String) async -> JSONValue? {
        let status = await call(
            harness, "status", ["operation": ["holder_id": .string(holder), "operation_id": .string(operation)]])
        return status.structuredContent?["operation"]
    }

    @Test("the call over the ceiling is refused with the time until the oldest counted call leaves the window")
    func ceilingAndRetryAfter() async throws {
        let (harness, frame) = try await Self.ready(perMinute: 3)
        let first = harness.clock.reading.wall
        for operation in ["op-1", "op-2", "op-3"] {
            #expect(await Self.type(harness, frame: frame, operation).structuredContent?["status"] == "completed")
            harness.clock.advance(byMilliseconds: 10_000)
        }
        let posted = harness.desk.posted.count

        let limited = await Self.type(harness, frame: frame, "op-4")
        #expect(limited.status == .ok)
        #expect(limited.isError == true)
        let content = try #require(limited.structuredContent)
        #expect(content["code"] == "rate_limited")
        #expect(content["state"] == "ok")
        #expect(content["operation_id"] == "op-4")
        let elapsed = harness.clock.reading.wall.millisecondsSinceEpoch - first.millisecondsSinceEpoch
        #expect(content["retry_after_ms"] == JSONValue(Int(ActionCeiling.windowMs - elapsed)))
        #expect(content["details"] == nil)
        #expect(content["operation"] == nil)
        #expect(content["replayed"] == nil)
        #expect(limited.contentText == content)
        #expect(harness.desk.posted.count == posted)
        #expect(await Self.lookUp(harness, "op-4") == .null)
        guard case .refusal(let entry)? = await harness.log.entries.last else {
            Issue.record("expected a refusal entry")
            return
        }
        #expect(entry.code == .rateLimited)

        harness.clock.advance(byMilliseconds: ActionCeiling.windowMs - elapsed)
        let fresh = try await Self.frame(harness)
        #expect(await Self.type(harness, frame: fresh, "op-4").structuredContent?["status"] == "completed")
        #expect(await Self.type(harness, frame: fresh, "op-5").structuredContent?["code"] == "rate_limited")
    }

    @Test("denied_app and denied_shortcut count toward the ceiling; replays and other refusals do not")
    func whatCounts() async throws {
        let (harness, frame) = try await Self.ready(perMinute: 3)
        #expect(await Self.type(harness, frame: frame, "op-1").structuredContent?["status"] == "completed")

        for _ in 0..<3 {
            #expect(await Self.type(harness, frame: frame, "op-1").structuredContent?["replayed"] == true)
            #expect(
                await Self.type(harness, frame: "frm_AAAAAAAAAAAAAAAAAAAAAA", "op-stale").structuredContent?["code"]
                    == "stale_frame")
            let invalid = await Self.call(
                harness, "keyboard",
                [
                    "holder_id": .string(Self.holder), "frame_id": .string(frame), "operation_id": "op-bad",
                    "action": ["type": "type", "text": "two\nlines"],
                ])
            #expect(invalid.structuredContent?["code"] == "invalid_argument")
            #expect(
                await Self.type(harness, frame: frame, "op-other", holder: "crew:beta").structuredContent?["code"]
                    == "lease_held_by_other")
        }

        let shortcut = await Self.spotlight(harness, frame: frame, "op-spotlight")
        #expect(shortcut.structuredContent?["code"] == "denied_shortcut")
        #expect(shortcut.structuredContent?["details"] == ["shortcut": "command+space"])
        harness.desk.change { $0.frontmost = Self.terminal }
        let denied = await Self.click(harness, frame: frame, "op-terminal")
        #expect(denied.structuredContent?["code"] == "denied_app")
        #expect(denied.structuredContent?["measured"]?["frontmost_app"]?["bundle_id"] == "com.apple.Terminal")
        harness.desk.change { $0.frontmost = ToolFixture.textEdit }

        let limited = await Self.type(harness, frame: frame, "op-2")
        #expect(limited.structuredContent?["code"] == "rate_limited")
        let deniedAtCeiling = await Self.spotlight(harness, frame: frame, "op-spotlight")
        #expect(deniedAtCeiling.structuredContent?["code"] == "rate_limited")
        #expect(await Self.lookUp(harness, "op-2") == .null)
    }

    @Test("one ceiling per Mac: another holder is limited too, and releasing the lease does not reset it")
    func perMac() async throws {
        let (harness, frame) = try await Self.ready(perMinute: 2)
        for operation in ["op-1", "op-2"] {
            #expect(await Self.type(harness, frame: frame, operation).structuredContent?["status"] == "completed")
        }
        #expect(
            await Self.type(harness, frame: frame, "op-3", holder: "crew:beta").structuredContent?["code"]
                == "lease_held_by_other")
        #expect(
            await Self.type(harness, frame: "frm_AAAAAAAAAAAAAAAAAAAAAA", "op-3").structuredContent?["code"]
                == "rate_limited")

        _ = await Self.call(harness, "lease", ["op": "release", "holder_id": .string(Self.holder)])
        _ = await Self.call(harness, "lease", ["op": "acquire", "holder_id": "crew:beta"])
        let other = try await Self.frame(harness, holder: "crew:beta")
        let limited = await Self.type(harness, frame: other, "op-3", holder: "crew:beta")
        #expect(limited.structuredContent?["code"] == "rate_limited")
        #expect(limited.structuredContent?["retry_after_ms"] != nil)

        let status = await Self.call(harness, "status", [:])
        #expect(status.structuredContent?["limits"]?["actions_per_minute"] == 2)
    }
}
