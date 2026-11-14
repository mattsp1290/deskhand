import Crypto
import DeskhandCore

extension DeskhandDispatcher {
    /// Captures one display or a region of it and mints a frame for (principal, `holder_id`)
    /// (contract 4.2, 6.3, 7). Refusals in the order of contract 9.5: the state's name, then
    /// `invalid_argument`, then `image_too_large`. A change of state away from `ok` before the
    /// frame is minted refuses the call with the new state's name and mints nothing (contract 10.3).
    public func screenshot(_ arguments: ScreenshotArguments, caller: ToolCaller) async throws(ToolError)
        -> CapturedScreenshot
    {
        let start = owner.beginCapture()
        if let blocking = start.state.blocking { throw Self.blocked(blocking) }
        let displays: DisplayConfiguration
        do {
            displays = try owner.displays.configuration()
        } catch {
            throw internalError(error.detail)
        }
        let area: CaptureArea
        do {
            area = try CaptureArea.resolve(displayID: arguments.displayID, region: arguments.region, in: displays)
        } catch {
            switch error {
            case .invalidArgument(let error):
                throw ToolError(.invalidArgument(error.pointer), message: error.description, state: start.state)
            case .fault(let fault): throw internalError(fault.detail)
            }
        }
        let request = CaptureRequest(
            display: area.display, captureRect: area.captureRect, sourcePixelSize: area.sourcePixelSize,
            format: arguments.format, maxLongEdge: arguments.maxLongEdge, policy: start.policy)
        let expected: ScreenshotSize
        do {
            expected = try request.size
        } catch {
            throw internalError("The capture cannot be sized: \(error).")
        }

        let before = platform.identity.frontmostApp()
        let image: CapturedImage
        do {
            image = try await platform.capturer.capture(request)
        } catch {
            try refuseUnlessOK()
            switch error {
            case .imageTooLarge(let imageBytes):
                throw ToolError(
                    .imageTooLarge(imageBytes: imageBytes), message: Self.imageTooLargeMessage, state: start.state)
            case .failed(let fault): throw internalError(fault.detail)
            }
        }
        let after = platform.identity.frontmostApp()
        // Nobody is left to receive the image, so no frame is minted for it.
        guard !Task.isCancelled else { throw internalError("The caller closed the connection.") }
        guard image.size == expected, image.pixels.size == expected.output, !image.bytes.isEmpty,
            let geometry = FrameGeometry(
                captureRect: area.captureRect, outputPixelSize: expected.output, displayBounds: area.display.bounds)
        else {
            try refuseUnlessOK()
            throw internalError("The platform's capture does not match the request.")
        }

        let capture = FrameCapture(
            displayID: area.display.displayID, displayConfigGeneration: displays.generation, geometry: geometry,
            sourcePixelSize: area.sourcePixelSize, pointPixelScale: area.display.pointPixelScale,
            downscale: expected.downscale, capturedAt: start.reading.wall, maxAgeMs: configuration.limits.frameMaxAgeMs,
            frontmostApp: Self.frontmostAtCapture(before: before, after: after),
            sha256: SHA256Hex(hashing: image.bytes), pixels: image.pixels)
        let frame: Frame
        do {
            frame = try owner.record(
                capture, for: FrameScope(principal: caller.principal, holderID: arguments.holderID), startedIn: start)
        } catch {
            switch error {
            case .blocked(let state): throw Self.blocked(state)
            case .inconsistentCapture: throw internalError("The platform's capture does not match the request.")
            }
        }
        let result = ScreenshotResult(
            frameID: frame.id, sha256: frame.sha256, displayID: frame.displayID,
            displayConfigGeneration: frame.displayConfigGeneration, captureRect: frame.captureRect,
            sourcePixelSize: frame.sourcePixelSize, outputPixelSize: frame.outputPixelSize,
            pointPixelScale: frame.pointPixelScale, downscale: frame.downscale, encoding: image.encoding,
            imageBytes: image.bytes.count, capturedAt: frame.capturedAt, maxAgeMs: frame.maxAgeMs,
            pointerPosition: image.pointerLocation.flatMap(geometry.framePoint(for:)), frontmostApp: frame.frontmostApp)
        return CapturedScreenshot(result: result, image: image.bytes)
    }

    static let imageTooLargeMessage =
        "The encoded image is over \(ContractConstants.maxImageBytes) bytes. Ask for jpeg or a smaller max_long_edge."

    /// The frontmost app at capture, read before and after it. When the two readings differ, or
    /// either is uncertain, deskhand cannot say which app was in front, so the frame records an
    /// undetermined app: a `keyboard` call on it is then refused as `frontmost_changed`, failing
    /// closed (contract 6.3, 8.3).
    static func frontmostAtCapture(before: ObservedApp, after: ObservedApp) -> AppRef {
        guard before.isCertain, after.isCertain, before.appRef == after.appRef else { return .undetermined }
        return after.appRef
    }
}
