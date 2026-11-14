import DeskhandCore

/// One screenshot as returned to the caller (contract 6.3, 7), with the pixels the frame keeps.
public struct EncodedScreenshot: Sendable {
    /// The image block's bytes before base64. `sha256` and `image_bytes` are of these.
    public let bytes: [UInt8]
    public let encoding: ImageEncoding
    /// `output` is the frame pixel space; `downscale` is reported as is.
    public let size: ScreenshotSize
    /// The output pixels as drawn before encoding, for the target-patch check (contract 8.4).
    public let pixels: FramePixels

    public var mimeType: String { encoding.format.mimeType }
    public var imageBytes: Int { bytes.count }
    public var outputPixelSize: PixelSize { size.output }
    public var downscale: Double { size.downscale }

    /// `nil` for PNG.
    public var jpegQuality: JPEGQuality? {
        guard case .jpeg(let quality) = encoding else { return nil }
        return quality
    }
}
