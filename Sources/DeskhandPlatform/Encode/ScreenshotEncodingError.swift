import DeskhandCore

/// Why a capture could not be returned as a screenshot.
public enum ScreenshotEncodingError: Error, Hashable, Sendable {
    /// `max_long_edge` out of range (the caller's), or a source with an empty side (a fault).
    case sizing(ScreenshotSizingError)
    /// The last encoding tried was over the byte limit: quality 60 for JPEG, the only attempt for PNG.
    case imageTooLarge(imageBytes: Int, maxImageBytes: Int)
    /// CoreGraphics could not draw the source into an sRGB bitmap of this size.
    case renderFailed(PixelSize)
    /// ImageIO could not encode the bitmap.
    case encodeFailed(ImageEncoding)

    /// The tool error this is (contract 7, 9.3): `invalid_argument`, `image_too_large`, or
    /// `internal_error` for anything that is not the caller's.
    public var reason: ToolErrorReason {
        switch self {
        case .sizing(let error): error.argumentError.map { .invalidArgument($0.pointer) } ?? .internalError
        case .imageTooLarge(let imageBytes, _): .imageTooLarge(imageBytes: imageBytes)
        case .renderFailed, .encodeFailed: .internalError
        }
    }
}
