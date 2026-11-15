import DeskhandCore
import Synchronization

/// A fault on the Mac that is not the caller's: answered with `internal_error`.
public struct PlatformFault: Error, Hashable, Sendable {
    /// For the log and the error's `message`; never a credential or a window title.
    public let detail: String

    public init(_ detail: String) { self.detail = detail }
}

/// The active displays as one configuration (contract 6.2).
public struct DisplayConfiguration: Hashable, Sendable {
    public var generation: DisplayConfigGeneration
    /// One entry per active display; in a mirror set only the primary.
    public var displays: [DisplayInfo]

    public init(generation: DisplayConfigGeneration, displays: [DisplayInfo]) {
        self.generation = generation
        self.displays = displays
    }

    /// The display a `screenshot` without `display_id` captures.
    public var main: DisplayInfo? { displays.first(where: \.isMain) }

    public func display(_ id: DisplayID) -> DisplayInfo? { displays.first { $0.displayID == id } }
}

/// The Mac's displays. The platform implements it.
public protocol DisplayProvider: Sendable {
    /// `display_config_generation` now: strictly increasing within one run, changed whenever the
    /// arrangement, a mode or a scale changes (contract 6.2). Read on every `status` and every frame
    /// check, so it must answer without waiting.
    var generation: DisplayConfigGeneration { get }

    /// The active displays, and the generation they were read under.
    func configuration() throws(PlatformFault) -> DisplayConfiguration
}

/// One capture the server asks the platform for (contract 6.3, 7). The server has already chosen
/// the display, aligned the region and sized the output; the platform captures, scales and encodes.
public struct CaptureRequest: Sendable {
    public let display: DisplayInfo
    /// Global points, aligned outward to whole native pixels of `display`.
    public let captureRect: GlobalRect
    /// Native pixels of `captureRect`.
    public let sourcePixelSize: PixelSize
    public let format: ImageFormat
    public let maxLongEdge: Int
    /// Measured before base64. JPEG steps down through its qualities until it fits; PNG does not.
    public let maxImageBytes: Int
    /// The policy in force: whose windows the image leaves out.
    public let policy: AppPolicy

    public init(
        display: DisplayInfo, captureRect: GlobalRect, sourcePixelSize: PixelSize, format: ImageFormat,
        maxLongEdge: Int, maxImageBytes: Int = ContractConstants.maxImageBytes, policy: AppPolicy
    ) {
        self.display = display
        self.captureRect = captureRect
        self.sourcePixelSize = sourcePixelSize
        self.format = format
        self.maxLongEdge = maxLongEdge
        self.maxImageBytes = maxImageBytes
        self.policy = policy
    }

    /// Whether the windows of an app with this bundle identifier are left out of the image: the
    /// Mac's capture exclusion list and deskhand's own bundle (contract 6.3, 6.9).
    public func excludes(_ bundleID: BundleID) -> Bool { policy.excludesFromCapture(bundleID) }

    /// The output size the image must have.
    public var size: ScreenshotSize {
        get throws(ScreenshotSizingError) { try ScreenshotSize(source: sourcePixelSize, maxLongEdge: maxLongEdge) }
    }
}

/// What the platform returns for a ``CaptureRequest``: the encoded image and the pixels it was
/// encoded from, which the frame keeps for the target-patch check (contract 8.4).
public struct CapturedImage: Sendable {
    /// The image block's bytes, before base64. Without the pointer and without excluded windows.
    public var bytes: [UInt8]
    public var encoding: ImageEncoding
    /// `ScreenshotSize(source: request.sourcePixelSize, maxLongEdge: request.maxLongEdge)`.
    public var size: ScreenshotSize
    /// Of `size.output`: 8-bit sRGB, no alpha, as drawn before encoding.
    public var pixels: FramePixels
    /// Where the pointer was at capture, in global points; `nil` when it could not be read.
    public var pointerLocation: GlobalPoint?

    public init(
        bytes: [UInt8], encoding: ImageEncoding, size: ScreenshotSize, pixels: FramePixels,
        pointerLocation: GlobalPoint?
    ) {
        self.bytes = bytes
        self.encoding = encoding
        self.size = size
        self.pixels = pixels
        self.pointerLocation = pointerLocation
    }
}

public enum CaptureFailure: Error, Hashable, Sendable {
    /// The last encoding tried was over `maxImageBytes`: `image_too_large`, no frame (contract 7).
    case imageTooLarge(imageBytes: Int)
    /// Anything else: `internal_error`.
    case failed(PlatformFault)
}

/// Captures the screen. The platform implements it with ScreenCaptureKit (deskhand-jnt5); the
/// server stays free of every image framework.
public protocol ScreenCapturer: Sendable {
    func capture(_ request: CaptureRequest) async throws(CaptureFailure) -> CapturedImage
}

/// Conditions that something outside the state reduction knows the live value of (contract 11).
public protocol ConditionsProvider: Sendable {
    /// Which of `credentials_warning` and `log_unavailable` hold now. Read on every `status`;
    /// anything else it returns is ignored, because each condition has one source.
    func conditions() -> Set<Condition>
}

/// `credentials_warning` from the credential reloader and `log_unavailable` from the outcome of
/// the latest append to the action log, which the app's ``ExecutorObserver`` forwards with
/// ``actionLogDidAppend(succeeded:)``. Safe to call from the executor without waiting.
public final class LiveConditions: ConditionsProvider {
    private let credentialsWarning: @Sendable () -> Bool
    private let logUnavailable = Mutex(false)

    /// `credentialsWarning` is read on every `status`, for example `{ reloader.status.credentialsWarning }`.
    public init(credentialsWarning: @escaping @Sendable () -> Bool = { false }) {
        self.credentialsWarning = credentialsWarning
    }

    /// Set when an append fails, cleared when one succeeds (contract 11.3).
    public func actionLogDidAppend(succeeded: Bool) { logUnavailable.withLock { $0 = !succeeded } }

    public func conditions() -> Set<Condition> {
        var conditions: Set<Condition> = []
        if credentialsWarning() { conditions.insert(.credentialsWarning) }
        if logUnavailable.withLock({ $0 }) { conditions.insert(.logUnavailable) }
        return conditions
    }
}
