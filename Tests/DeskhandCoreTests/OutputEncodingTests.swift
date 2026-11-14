import DeskhandCore
import Foundation
import Testing

/// Each valid output example, rebuilt from the result models. Timestamps are milliseconds since the
/// epoch of the example's RFC 3339 strings.
private enum Examples {
    static let holder = HolderID("crew:inst-7f3a:desk-lunus")!
    static let frame = FrameID("frm_Zk3vQ8sN1xT5bYc2Lw9RaA")!
    static let textEdit = AppRef(bundleID: "com.apple.TextEdit", teamID: nil, name: "TextEdit")
    static let pointerPoint = GlobalPoint(x: 883.8114649681529, y: 571.3432982917215)
    static let pointerMeasured = measured(target: textEdit, title: "notes.txt")
    static let keyboardMeasured = Measured(
        frontmostApp: textEdit, targetApp: textEdit, windowTitle: "notes.txt", globalPoint: nil,
        measuredAt: at(1_794_668_544_105))
    static let heldLease = LeaseView.heldByCaller(
        acquiredAt: at(1_794_668_531_482), expiresAt: at(1_794_668_561_482), expiresInMs: 30_000)
    static let armedUntil = at(1_794_672_000_000)

    static func at(_ milliseconds: Int64) -> Timestamp { Timestamp(millisecondsSinceEpoch: milliseconds) }
    static func op(_ raw: String) -> OperationID { OperationID(raw)! }

    static func measured(target: AppRef, title: String?, point: GlobalPoint = pointerPoint) -> Measured {
        Measured(
            frontmostApp: textEdit, targetApp: target, windowTitle: title, globalPoint: point,
            measuredAt: at(1_794_668_539_730))
    }

    static func status(
        _ active: ActiveStates, _ conditions: Set<Condition> = [], armedUntil: Timestamp? = armedUntil,
        lease: LeaseView?, operation: StatusOperation? = nil
    ) -> StatusResult {
        StatusResult(
            serverVersion: "0.1.0", mac: "lunus-macbook-pro", time: at(1_794_668_531_482),
            startedAt: at(1_794_663_602_000), activeStates: active, conditions: conditions, armedUntil: armedUntil,
            lease: lease, operation: operation, displayConfigGeneration: DisplayConfigGeneration(3), limits: Limits())
    }

    static func lease(_ op: LeaseOperation, _ outcome: LeaseOutcome, _ view: LeaseView = .notHeldByCaller)
        -> LeaseToolResult
    {
        LeaseToolResult(result: LeaseResult(operation: op, outcome: outcome), lease: view)
    }

    static func effect(_ id: String, events: Int, replayed: Bool, measured: Measured, completedAt: Int64)
        -> EffectResult
    {
        EffectResult(
            operationID: op(id), frameID: frame, eventsPosted: events, replayed: replayed, measured: measured,
            completedAt: at(completedAt))
    }

    static func display(
        _ id: UInt32, _ uuid: String, _ name: String, main: Bool, bounds: GlobalRect, pixels: PixelSize, scale: Double
    )
        -> DisplayInfo
    {
        DisplayInfo(
            displayID: DisplayID(id), uuid: UUID(uuidString: uuid)!, name: name, isMain: main, isBuiltin: main,
            asleep: false,
            bounds: bounds, pixelSize: pixels, pointPixelScale: scale)
    }

    static func screenshot(
        _ frame: FrameID, sha: String, rect: GlobalRect, source: PixelSize, output: PixelSize, downscale: Double,
        encoding: ImageEncoding, bytes: Int, pointer: FramePoint?
    ) -> ScreenshotResult {
        ScreenshotResult(
            frameID: frame, sha256: SHA256Hex(hex: sha)!, displayID: DisplayID(1),
            displayConfigGeneration: DisplayConfigGeneration(3), captureRect: rect, sourcePixelSize: source,
            outputPixelSize: output, pointPixelScale: 2, downscale: downscale, encoding: encoding, imageBytes: bytes,
            capturedAt: at(1_794_668_534_019), maxAgeMs: 60_000, pointerPosition: pointer, frontmostApp: textEdit)
    }

    static let all: [String: any JSONRepresentable & Sendable] = [
        "status.output.ok-no-holder.json": status(.none, lease: nil),
        "status.output.ok-holder-holds.json": status(.none, lease: heldLease),
        "status.output.ok-holder-does-not-hold.json": status(.none, lease: .notHeldByCaller),
        "status.output.disarmed.json": status(
            ActiveStates([.locked, .disarmed]), [.credentialsWarning], armedUntil: nil, lease: .notHeldByCaller),
        "status.output.gated-and-disarmed.json": status(
            ActiveStates([.gated, .disarmed]), armedUntil: nil, lease: nil),
        "status.output.operation-found.json": status(
            .none, lease: heldLease, operation: .found(OperationView(status: .completed, eventsPosted: 3))),
        "status.output.operation-unknown.json": status(.none, lease: heldLease, operation: .notFound),
        "status.output.error-invalid-argument.json": ToolError(
            .invalidArgument(JSONPointer(["operation"])), message: "operation needs both holder_id and operation_id.",
            state: .ok),
        "lease.output.acquired.json": lease(.acquire, .acquired, heldLease),
        "lease.output.acquire-renewed.json": lease(.acquire, .renewed, heldLease),
        "lease.output.renewed.json": lease(.renew, .renewed, heldLease),
        "lease.output.released.json": lease(.release, .released),
        "lease.output.release-not-held.json": lease(.release, .notHeld),
        "lease.output.refused-disarmed.json": lease(.acquire, .refused(.state(.disarmed))),
        "lease.output.refused-held-by-other.json": lease(.acquire, .refused(.leaseHeldByOther(expiresInMs: 21_500))),
        "lease.output.renew-refused-expired.json": lease(.renew, .refused(.leaseExpired)),
        "lease.output.error-invalid-argument.json": ToolError(
            .invalidArgument(JSONPointer(["ttl_ms"])), message: "ttl_ms must be absent on release.", state: .ok),
        "displays.output.two-displays.json": DisplaysResult(
            displayConfigGeneration: DisplayConfigGeneration(3),
            displays: [
                display(
                    1, "37D8832A-2D66-02CA-B9F7-8F30A301B230", "Built-in Retina Display", main: true,
                    bounds: GlobalRect(x: 0, y: 0, width: 1728, height: 1117),
                    pixels: PixelSize(width: 3456, height: 2234),
                    scale: 2),
                display(
                    2, "5F1A0C44-9B1E-4E0D-8C2B-6A7D3E9F0B12", "DELL U2723QE", main: false,
                    bounds: GlobalRect(x: -2560, y: 0, width: 2560, height: 1440),
                    pixels: PixelSize(width: 2560, height: 1440), scale: 1),
            ]),
        "displays.output.error-disarmed.json": ToolError(
            .blocked(.disarmed), message: "deskhand is disarmed. A person at the Mac must arm it from the menu bar.",
            state: .disarmed),
        "screenshot.output.jpeg.json": screenshot(
            frame, sha: "8db1f90ff7b0eb8bba6ff6d12c7ca55223f3c4a755ffa66f0f2ab19d83c8f089",
            rect: GlobalRect(x: 0, y: 0, width: 1728, height: 1117), source: PixelSize(width: 3456, height: 2234),
            output: PixelSize(width: 2355, height: 1522), downscale: 0.6817070194446376, encoding: .jpeg(.q85),
            bytes: 1_184_213, pointer: FramePoint(x: 1630, y: 912)),
        "screenshot.output.png-region.json": screenshot(
            FrameID("frm_p0Hq7mVd2KxE9sWb4TnJcQ")!,
            sha: "9910444f3b25588fac08900eefe01593f9b338318464525a022d8694a090aa39",
            rect: GlobalRect(x: 200, y: 120, width: 800, height: 600), source: PixelSize(width: 1600, height: 1200),
            output: PixelSize(width: 1600, height: 1200), downscale: 1, encoding: .png, bytes: 2_310_447, pointer: nil),
        "screenshot.output.error-gated.json": ToolError(
            .blocked(.gated), message: "The LAN gate allowance is missing or expired.", state: .gated),
        "screenshot.output.error-image-too-large.json": ToolError(
            .imageTooLarge(imageBytes: 7_204_113),
            message: "The PNG is 7204113 bytes; the limit is 3750000. Ask for jpeg or a smaller max_long_edge.",
            state: .ok),
        "pointer.output.completed.json": effect(
            "call_01HZX3M9Q3", events: 3, replayed: false, measured: pointerMeasured, completedAt: 1_794_668_539_781),
        "pointer.output.completed-drag.json": effect(
            "call_01HZX3M9Q5", events: 34, replayed: false,
            measured: Measured(
                frontmostApp: textEdit, targetApp: textEdit, windowTitle: "notes.txt",
                globalPoint: GlobalPoint(x: 220.49426751592355, y: 293.92805519053877),
                dragEnd: DragEnd(
                    targetApp: textEdit, windowTitle: "notes.txt",
                    globalPoint: GlobalPoint(x: 381.92101910828023, y: 470.06471747700397)),
                measuredAt: at(1_794_668_539_730)), completedAt: 1_794_668_539_781),
        "pointer.output.error-denied-app.json": ToolError(
            .deniedApp(
                .permittedApps,
                measured: measured(
                    target: AppRef(bundleID: "com.apple.Preview", teamID: nil, name: "Preview"), title: "scan.pdf"),
                pointIndex: 0),
            message: "The window under the target belongs to an app that is not in permitted_apps.", state: .ok,
            operationID: op("call_01HZX3M9Q4")),
        "pointer.output.error-denied-app-no-window.json": ToolError(
            .deniedApp(.policy, measured: measured(target: .undetermined, title: nil), pointIndex: 0),
            message: "deskhand could not determine which app owns the window under the target.", state: .ok,
            operationID: op("call_01HZX3M9Q3")),
        "pointer.output.error-denied-app-drag-aborted.json": ToolError(
            .deniedApp(
                .policy,
                measured: Measured(
                    frontmostApp: textEdit, targetApp: AppRef(bundleID: "com.apple.mail", teamID: nil, name: "Mail"),
                    windowTitle: "Inbox", globalPoint: GlobalPoint(x: 381.92101910828023, y: 402.54566360052564),
                    measuredAt: at(1_794_668_540_214)),
                pointIndex: 2),
            message:
                "The drag was about to cross a window of an app that is not allowed. It was stopped and the button released.",
            state: .ok, operationID: op("call_01HZX3M9Q5"),
            operation: .result(OperationView(status: .aborted, eventsPosted: 19), replayed: false)),
        "pointer.output.error-lease-held-by-other.json": ToolError(
            .leaseHeldByOther(expiresInMs: 21_500), message: "Another holder has the lease.", state: .ok,
            operationID: op("call_01HZX3M9Q3")),
        "pointer.output.error-out-of-frame.json": ToolError(
            .outOfFrame(pointIndex: 0, outputPixelSize: PixelSize(width: 2355, height: 1522)),
            message: "Point 0 (2355, 778) is outside the 2355 x 1522 frame.", state: .ok,
            operationID: op("call_01HZX3M9Q3")),
        "pointer.output.error-paused-aborted.json": ToolError(
            .blocked(.paused), message: "The kill switch was used during the drag. The button was released.",
            state: .paused,
            operationID: op("call_01HZX3M9Q5"),
            operation: .result(OperationView(status: .aborted, eventsPosted: 5), replayed: false),
            measured: pointerMeasured),
        "pointer.output.error-stale-frame.json": ToolError(
            .staleFrame(.pixelsChanged(pointIndex: 0)),
            message: "The pixels around the target changed since the frame was captured. Take a new screenshot.",
            state: .ok,
            operationID: op("call_01HZX3M9Q3")),
        "pointer.output.error-stale-frame-before-first-event.json": ToolError(
            .staleFrame(.pixelsChanged(pointIndex: 0)),
            message:
                "The target patch was checked more than 250 ms before the first event could be posted. Nothing was posted. Take a new screenshot.",
            state: .ok, operationID: op("call_01HZX3M9Q3"),
            operation: .result(OperationView(status: .aborted, eventsPosted: 0), replayed: false),
            measured: pointerMeasured),
        "pointer.output.error-user-active-aborted.json": ToolError(
            .userActive(idleMs: 40),
            message:
                "The person at the Mac used the keyboard or pointer. The drag was aborted and the button released.",
            state: .ok, operationID: op("call_01HZX3M9Q5"),
            operation: .result(OperationView(status: .aborted, eventsPosted: 7), replayed: false),
            measured: pointerMeasured),
        "keyboard.output.completed.json": effect(
            "call_01HZX3M9R1", events: 66, replayed: false, measured: keyboardMeasured, completedAt: 1_794_668_544_512),
        "keyboard.output.replayed.json": effect(
            "call_01HZX3M9R1", events: 66, replayed: true, measured: keyboardMeasured, completedAt: 1_794_668_544_512),
        "keyboard.output.error-busy.json": ToolError(
            .busy, message: "Another effect call is being admitted or is executing.", state: .ok,
            operationID: op("call_01HZX3M9R2")),
        "keyboard.output.error-cancelled.json": ToolError(
            .cancelled,
            message: "The caller closed the connection during the earlier call. Typing stopped part-way.", state: .ok,
            operationID: op("call_01HZX3M9R1"),
            operation: .result(OperationView(status: .aborted, eventsPosted: 20), replayed: true),
            measured: keyboardMeasured),
        "keyboard.output.error-denied-app-focus.json": ToolError(
            .deniedApp(
                .policy,
                measured: Measured(
                    frontmostApp: textEdit,
                    targetApp: AppRef(bundleID: "com.apple.Spotlight", teamID: nil, name: "Spotlight"),
                    windowTitle: "Spotlight", globalPoint: nil, measuredAt: at(1_794_668_544_105)),
                pointIndex: nil),
            message: "Keyboard focus belongs to an app that is not allowed.", state: .ok,
            operationID: op("call_01HZX3M9R1")),
        "keyboard.output.error-denied-shortcut.json": ToolError(
            .deniedShortcut(shortcut: "command+space"),
            message: "command+space is a denied global shortcut on this Mac.",
            state: .ok, operationID: op("call_01HZX3M9R3")),
        "keyboard.output.error-interrupted.json": ToolError(
            .interrupted,
            message: "deskhand restarted while this operation was executing. Input may have been posted.", state: .ok,
            operationID: op("call_01HZX3M9R1"),
            operation: .result(OperationView(status: .abortedByRestart, eventsPosted: 12), replayed: true)),
        "keyboard.output.error-log-unavailable.json": ToolError(
            .logUnavailable(measured: keyboardMeasured),
            message: "The action log could not record the intent. Nothing was typed.",
            state: .ok, operationID: op("call_01HZX3M9R5")),
        "keyboard.output.error-operation-id-conflict.json": ToolError(
            .operationIDConflict, message: "operation_id was already used with different arguments.", state: .ok,
            operationID: op("call_01HZX3M9R1"),
            operation: .existing(OperationView(status: .completed, eventsPosted: 66))),
        "keyboard.output.error-operation-in-progress.json": ToolError(
            .operationInProgress, message: "An earlier call with this operation_id is still executing.", state: .ok,
            operationID: op("call_01HZX3M9R1"),
            operation: .existing(OperationView(status: .executing, eventsPosted: 12))),
        "keyboard.output.error-paused-repeat.json": ToolError(
            .blocked(.paused),
            message:
                "deskhand is paused. An earlier call with this operation_id typed 18 characters before it was stopped.",
            state: .paused, operationID: op("call_01HZX3M9R1"),
            operation: .existing(OperationView(status: .aborted, eventsPosted: 36))),
        "keyboard.output.error-rate-limited.json": ToolError(
            .rateLimited(retryAfterMs: 4200), message: "The per-minute action ceiling (60) is reached.", state: .ok,
            operationID: op("call_01HZX3M9R2")),
        "keyboard.output.error-secure-input-aborted.json": ToolError(
            .blocked(.secureInput), message: "Secure input turned on while typing. The rest of the text was not typed.",
            state: .secureInput, operationID: op("call_01HZX3M9R1"),
            operation: .result(OperationView(status: .aborted, eventsPosted: 18), replayed: false),
            measured: keyboardMeasured),
    ]
}

@Suite struct OutputEncodingTests {
    @Test(arguments: Fixtures.names(in: "examples", kind: ".output."))
    func modelEncodesToTheExample(name: String) throws {
        let model = try #require(Examples.all[name], "no model for \(name)")
        #expect(model.jsonValue == (try Fixtures.json("examples/\(name)")))
        _ = try model.jsonValue.canonicalBytes()
    }

    @Test func everyOutputExampleHasAModel() {
        #expect(Set(Fixtures.names(in: "examples", kind: ".output.")) == Set(Examples.all.keys))
    }

    @Test func requiredMeasuredComesFromTheReasonWithoutTitles() {
        let error = ToolError(
            .deniedApp(.policy, measured: Examples.keyboardMeasured, pointIndex: nil), message: "", state: .ok,
            measured: nil)
        #expect(error.jsonValue["measured"] == Examples.keyboardMeasured.withoutWindowTitles.jsonValue)
        #expect(error.jsonValue["measured"]?["window_title"] == .null)
        #expect(error.jsonValue["details"] == ["denied_by": "policy"])
        let drag = Measured(
            frontmostApp: Examples.textEdit, targetApp: Examples.textEdit, windowTitle: "a",
            globalPoint: Examples.pointerPoint,
            dragEnd: DragEnd(targetApp: Examples.textEdit, windowTitle: "b", globalPoint: Examples.pointerPoint),
            measuredAt: Examples.at(0))
        let denied = ToolError(.deniedApp(.policy, measured: drag, pointIndex: 3), message: "", state: .ok)
        #expect(denied.jsonValue["measured"]?["drag_end"]?["window_title"] == .null)
        #expect(denied.jsonValue["details"] == ["denied_by": "policy", "point_index": 3])
    }

    @Test func staleFrameCarriesPointIndexOnlyForPixelsChanged() {
        let error = ToolError(.staleFrame(.tooOld), message: "", state: .ok)
        #expect(error.jsonValue["details"] == ["reason": "too_old"])
        #expect(error.jsonValue["replayed"] == nil && error.jsonValue["operation"] == nil)
    }

    @Test func windowTitleIsCutTo512UnicodeScalars() {
        let measured = Measured(
            frontmostApp: Examples.textEdit, targetApp: nil, windowTitle: String(repeating: "é", count: 600),
            globalPoint: nil,
            measuredAt: Examples.at(0))
        #expect(measured.windowTitle?.unicodeScalars.count == 512)
        // 300 graphemes of two scalars each: a cut by characters would keep 600 scalars.
        let combining = String(repeating: "e\u{301}", count: 300)
        let end = DragEnd(targetApp: Examples.textEdit, windowTitle: combining, globalPoint: Examples.pointerPoint)
        #expect(end.windowTitle?.unicodeScalars.count == 512)
    }

    @Test func jsonRPCErrorsMatchTheWireExamples() throws {
        let unknownTool = try Fixtures.json("examples/wire/error.unknown-tool.response.json")
        #expect(JSONRPCError.unknownTool("clipboard").jsonValue == unknownTool["error"])
        let mismatch = try Fixtures.json("examples/wire/error.header-mismatch.response.json")
        let error = JSONRPCError(
            .headerMismatch,
            data: ["header": "Mcp-Name", "detail": "Mcp-Name is 'pointer' but params.name is 'keyboard'."])
        #expect(error.jsonValue == mismatch["error"])
    }
}
