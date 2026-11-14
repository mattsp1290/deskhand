import DeskhandCore
import Foundation
import Testing

@testable import DeskhandServer

@Suite("displays")
struct DisplaysToolTests {
    @Test("lists the active displays under their generation")
    func lists() async throws {
        let harness = try ToolHarness()
        let result = try await harness.dispatcher.displays(caller: ToolFixture.caller)
        #expect(result.displayConfigGeneration == ToolFixture.generation)
        #expect(result.displays == [ToolFixture.main, ToolFixture.side])
    }

    @Test("is refused with the state's name", arguments: [BlockingState.gated, .locked, .secureInput])
    func refusedWhenBlocked(state: BlockingState) async throws {
        let harness = try ToolHarness()
        harness.hold([state])
        let error = await refusal { () async throws(ToolError) in
            try await harness.dispatcher.displays(caller: ToolFixture.caller)
        }
        #expect(error?.code.rawValue == state.rawValue)
        #expect(error?.state == state.state)
    }

    @Test("a display list that cannot be read is internal_error")
    func platformFault() async throws {
        let harness = try ToolHarness()
        harness.displays.failReads()
        let error = await refusal { () async throws(ToolError) in
            try await harness.dispatcher.displays(caller: ToolFixture.caller)
        }
        #expect(error?.code == .internalError)
    }
}

@Suite("screenshot")
struct ScreenshotToolTests {
    @Test("captures the main display, sized and described by contract 6.3 and 7")
    func mainDisplay() async throws {
        let harness = try ToolHarness(limits: Limits(frameMaxAgeMs: 45_000))
        let shot = try await harness.screenshot()
        let request = try #require(harness.capturer.requests.last)
        #expect(request.display == ToolFixture.main)
        #expect(request.captureRect == ToolFixture.main.bounds)
        #expect(request.sourcePixelSize == ToolFixture.main.pixelSize)
        #expect(request.maxLongEdge == 2576)
        #expect(request.maxImageBytes == 3_750_000)

        let result = shot.result
        #expect(result.frameID.rawValue.hasPrefix("frm_"))
        #expect(result.frameID.rawValue.count == 26)
        #expect(result.sha256 == SHA256Hex(hashing: shot.image))
        #expect(result.imageBytes == shot.image.count)
        #expect(result.displayID == ToolFixture.main.displayID)
        #expect(result.displayConfigGeneration == ToolFixture.generation)
        #expect(result.captureRect == ToolFixture.main.bounds)
        #expect(result.sourcePixelSize == PixelSize(width: 3456, height: 2234))
        #expect(result.outputPixelSize == PixelSize(width: 2355, height: 1522))
        #expect(result.downscale > 0.68 && result.downscale < 0.682)
        #expect(result.pointPixelScale == 2)
        #expect(result.encoding == .jpeg(.q85))
        #expect(result.jsonValue["jpeg_quality"] == 85)
        #expect(result.capturedAt == ToolFixture.t0.wall)
        #expect(result.maxAgeMs == 45_000)
        // The fake pointer is at (100, 50) points: pixel (100 * 2355 / 1728, 50 * 1522 / 1117).
        #expect(result.pointerPosition == FramePoint(x: 136, y: 68))
        #expect(result.frontmostApp == ToolFixture.textEdit.appRef)
        #expect(await harness.check(result.frameID) == nil)
    }

    @Test("max_long_edge, PNG, and a pointer outside the frame")
    func options() async throws {
        let harness = try ToolHarness()
        harness.capturer.configure { $0.pointer = GlobalPoint(x: -5, y: 10) }
        let shot = try await harness.screenshot(ToolHarness.shot(["max_long_edge": 1568, "format": "png"]))
        #expect(shot.result.outputPixelSize == PixelSize(width: 1568, height: 1013))
        #expect(shot.result.encoding == .png)
        #expect(shot.result.jsonValue["jpeg_quality"] == nil)
        #expect(shot.result.jsonValue["mime_type"] == "image/png")
        #expect(shot.result.pointerPosition == nil)
        #expect(shot.result.jsonValue["pointer_position"] == .null)
    }

    @Test("a region is aligned outward to whole native pixels")
    func regionAlignment() async throws {
        let harness = try ToolHarness()
        let region: JSONValue = ["x": 10.25, "y": 20.3, "width": 100.5, "height": 50]
        let shot = try await harness.screenshot(ToolHarness.shot(["region": region]))
        // At 2 pixels per point: x 20.5..221.5 -> 20..222, y 40.6..140.6 -> 40..141.
        #expect(shot.result.captureRect == GlobalRect(x: 10, y: 20, width: 101, height: 50.5))
        #expect(shot.result.sourcePixelSize == PixelSize(width: 202, height: 101))
        #expect(shot.result.outputPixelSize == PixelSize(width: 202, height: 101))
        #expect(shot.result.downscale == 1)

        let side: JSONValue = ["x": -1920, "y": 0, "width": 1920, "height": 1080]
        let sideShot = try await harness.screenshot(ToolHarness.shot(["display_id": 2, "region": side]))
        #expect(sideShot.result.captureRect == ToolFixture.side.bounds)
        #expect(sideShot.result.displayID == DisplayID(2))
        #expect(sideShot.result.pointerPosition == nil)

        // An edge on the pixel grid stays where it is; one between pixels moves outward.
        let onGrid: JSONValue = ["x": -100, "y": 0.5, "width": 1, "height": 1]
        let gridShot = try await harness.screenshot(ToolHarness.shot(["display_id": 2, "region": onGrid]))
        #expect(gridShot.result.captureRect == GlobalRect(x: -100, y: 0, width: 1, height: 2))
        #expect(gridShot.result.sourcePixelSize == PixelSize(width: 1, height: 2))
    }

    @Test("an inactive display_id or a region outside the display is invalid_argument")
    func invalidArguments() async throws {
        let harness = try ToolHarness()
        let cases: [(JSONObject, String)] = [
            (["display_id": 9], "/display_id"),
            (["region": ["x": 1700, "y": 0, "width": 29, "height": 10]], "/region"),
            (["region": ["x": -1, "y": 0, "width": 10, "height": 10]], "/region"),
            (["display_id": 2, "region": ["x": 0, "y": 0, "width": 10, "height": 10]], "/region"),
        ]
        for (arguments, pointer) in cases {
            let error = await refusal { () async throws(ToolError) in
                try await harness.screenshot(ToolHarness.shot(arguments))
            }
            #expect(error?.code == .invalidArgument)
            #expect(error?.jsonValue["details"]?["argument"]?.stringValue == pointer)
        }
        #expect(harness.capturer.requests.isEmpty)
    }

    @Test("refusals come in the order of contract 9.5: state, invalid_argument, image_too_large")
    func refusalOrder() async throws {
        let harness = try ToolHarness()
        harness.capturer.configure { $0.tooLarge = 3_900_000 }
        let tooLarge = await refusal { () async throws(ToolError) in try await harness.screenshot() }
        #expect(tooLarge?.code == .imageTooLarge)
        #expect(tooLarge?.jsonValue["details"] == ["image_bytes": 3_900_000, "max_image_bytes": 3_750_000])

        let invalid = await refusal { () async throws(ToolError) in
            try await harness.screenshot(ToolHarness.shot(["display_id": 9]))
        }
        #expect(invalid?.code == .invalidArgument)

        harness.hold([.permissionStale])
        let blocked = await refusal { () async throws(ToolError) in
            try await harness.screenshot(ToolHarness.shot(["display_id": 9]))
        }
        #expect(blocked?.code == .permissionStale)
        let schemaFault = await harness.dispatcher.refusal(
            .invalidArguments(ArgumentError(at: JSONPointer(["max_long_edge"]), "must be an integer")),
            tool: .screenshot, handles: EffectHandles(arguments: [:]), caller: ToolFixture.caller)
        #expect(schemaFault.code == .permissionStale)
    }

    @Test("image_too_large and a capture fault mint no frame")
    func noFrameOnFailure() async throws {
        let harness = try ToolHarness()
        let first = try await harness.screenshot().result.frameID
        harness.capturer.configure { $0.tooLarge = 4_000_000 }
        _ = await refusal { () async throws(ToolError) in try await harness.screenshot() }
        harness.capturer.configure {
            $0.tooLarge = nil
            $0.fault = true
        }
        let fault = await refusal { () async throws(ToolError) in try await harness.screenshot() }
        #expect(fault?.code == .internalError)
        #expect(await harness.check(first) == nil)
    }

    @Test("a capture that disagrees with its request is internal_error")
    func inconsistentCapture() async throws {
        let harness = try ToolHarness()
        let wrong = try ScreenshotSize(source: PixelSize(width: 100, height: 100))
        harness.capturer.configure { $0.reportedSize = wrong }
        let error = await refusal { () async throws(ToolError) in try await harness.screenshot() }
        #expect(error?.code == .internalError)
    }

    @Test("excludes the Mac's capture exclusion list and deskhand's own bundle")
    func captureExclusions() async throws {
        let harness = try ToolHarness()
        _ = try await harness.screenshot()
        let request = try #require(harness.capturer.requests.last)
        #expect(request.excludes(ToolFixture.deskhandBundle))
        #expect(request.excludes(BundleID("com.birbhomes.deskhand.indicator")!))
        #expect(request.excludes(BundleID("com.apple.Terminal")!))
        #expect(!request.excludes(BundleID("com.apple.TextEdit")!))

        var policy = ToolFixture.policy
        policy.captureExclusions = [BundleIDFamily(BundleID("com.apple.TextEdit")!)]
        harness.owner.updatePolicy(policy)
        _ = try await harness.screenshot()
        #expect(try #require(harness.capturer.requests.last).excludes(BundleID("com.apple.TextEdit")!))
    }

    @Test("a frame belongs to the principal and holder that took it")
    func scoping() async throws {
        let harness = try ToolHarness()
        let frame = try await harness.screenshot().result.frameID
        #expect(await harness.check(frame) == nil)
        #expect(await harness.check(frame, holder: ToolFixture.otherHolder) == .unknown)
        #expect(await harness.check(frame, caller: ToolFixture.otherCaller) == .unknown)
    }

    @Test("latest is judged per principal, holder and display")
    func latestNarrowing() async throws {
        let harness = try ToolHarness()
        let first = try await harness.screenshot().result.frameID
        _ = try await harness.screenshot(ToolHarness.shot(holder: ToolFixture.otherHolder))
        _ = try await harness.screenshot(caller: ToolFixture.otherCaller)
        _ = try await harness.screenshot(ToolHarness.shot(["display_id": 2]))
        #expect(await harness.check(first) == nil)

        let second = try await harness.screenshot().result.frameID
        #expect(await harness.check(first) == .notLatest)
        #expect(await harness.check(second) == nil)

        harness.displays.reconfigure()
        #expect(await harness.check(second) == .displayChanged)
    }

    @Test("is refused with the state's name before capturing", arguments: [BlockingState.disarmed, .displayAsleep])
    func refusedWhenBlocked(state: BlockingState) async throws {
        let harness = try ToolHarness()
        harness.hold([state])
        let error = await refusal { () async throws(ToolError) in try await harness.screenshot() }
        #expect(error?.code.rawValue == state.rawValue)
        #expect(harness.capturer.requests.isEmpty)
    }

    @Test("leaving ok during the capture refuses it with the new state's name and mints nothing")
    func stateChangesDuringCapture() async throws {
        let harness = try ToolHarness()
        let owner = harness.owner
        harness.capturer.configure {
            $0.during = { owner.reduce(signals: ToolFixture.signals(holding: [.locked])) }
        }
        let error = await refusal { () async throws(ToolError) in try await harness.screenshot() }
        #expect(error?.code == .locked)
        harness.hold([])

        // Back to `ok` before the capture returns: the frames were still invalidated meanwhile.
        harness.capturer.configure {
            $0.during = {
                owner.reduce(signals: ToolFixture.signals(holding: [.secureInput]))
                owner.reduce(signals: ToolFixture.signals())
            }
        }
        let flapped = await refusal { () async throws(ToolError) in try await harness.screenshot() }
        #expect(flapped?.code == .secureInput)

        harness.capturer.configure { $0.during = nil }
        #expect(try await harness.screenshot().result.frameID.rawValue.hasPrefix("frm_"))
    }

    @Test("leaving ok invalidates every frame")
    func invalidation() async throws {
        let harness = try ToolHarness()
        let frame = try await harness.screenshot().result.frameID
        harness.hold([.locked])
        harness.hold([])
        #expect(await harness.check(frame) == .unknown)
    }

    @Test("a frontmost app that changes during the capture is recorded as undetermined")
    func frontmostAtCapture() async throws {
        let harness = try ToolHarness()
        harness.desk.change { $0.nextFrontmost = [ToolFixture.textEdit, ToolFixture.notes] }
        let shot = try await harness.screenshot()
        #expect(shot.result.frontmostApp == .undetermined)
        #expect(
            await harness.check(shot.result.frameID, use: .keyboard(frontmostApp: ToolFixture.notes.appRef))
                == .frontmostChanged)

        harness.desk.change { $0.frontmost = ToolFixture.app("com.apple.Notes", "Notes", certain: false) }
        #expect(try await harness.screenshot().result.frontmostApp == .undetermined)
    }

    @Test("a caller that hung up gets no frame")
    func cancelled() async throws {
        let harness = try ToolHarness()
        let first = try await harness.screenshot().result.frameID
        let task = Task { () async -> ToolError? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await refusal { () async throws(ToolError) in try await harness.screenshot() }
        }
        #expect(await task.value?.code == .internalError)
        #expect(await harness.check(first) == nil)
    }

    @Test("the image block comes before the text block, through the MCP layer")
    func imageBlock() async throws {
        let harness = try ToolHarness()
        let handler = MCPHandler(dispatcher: harness.dispatcher, serverVersion: "0.1.0")
        let request = MCPTestRequest.tool("screenshot", ["holder_id": "crew:alpha", "format": "png"])
        let response = MCPTestResponse(await handler.handle(request.authenticated))
        #expect(response.isError == false)
        #expect(response.content.count == 2)
        #expect(response.content.first?["type"] == "image")
        #expect(response.content.first?["mimeType"] == "image/png")
        #expect(response.content.last?["type"] == "text")
        let data = try #require(response.content.first?["data"]?.stringValue)
        #expect(Data(base64Encoded: data)?.count == 1000)
        #expect(response.contentText == response.structuredContent)
    }
}
