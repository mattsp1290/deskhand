import CoreGraphics
import DeskhandCore
import ImageIO

/// Turns one capture into the returned image (contract 7): scaled to ``ScreenshotSize``, drawn into
/// an 8-bit sRGB bitmap without alpha, and encoded with no metadata (no EXIF, GPS, XMP or thumbnail).
/// Deterministic for a given image and arguments.
public enum ScreenshotEncoder {
    /// JPEG tries quality 85, 75, 65 and 60 and returns the first that is at most `maxImageBytes`;
    /// PNG is encoded once. Neither switches format. `maxImageBytes` is measured before base64.
    public static func encode(
        _ image: CGImage, format: ImageFormat, maxLongEdge: Int, maxImageBytes: Int
    ) throws(ScreenshotEncodingError) -> EncodedScreenshot {
        let size: ScreenshotSize
        do {
            size = try ScreenshotSize(
                source: PixelSize(width: image.width, height: image.height), maxLongEdge: maxLongEdge)
        } catch {
            throw .sizing(error)
        }
        let bitmap = try render(image, to: size.output)
        var bytes: [UInt8] = []
        for encoding in attempts(for: format) {
            bytes = try encode(bitmap.image, as: encoding)
            if bytes.count <= maxImageBytes {
                return EncodedScreenshot(bytes: bytes, encoding: encoding, size: size, pixels: bitmap.pixels)
            }
        }
        throw .imageTooLarge(imageBytes: bytes.count, maxImageBytes: maxImageBytes)
    }

    /// `image` drawn at `output` exactly as ``encode(_:format:maxLongEdge:maxImageBytes:)`` draws a
    /// frame, so a recapture for the target-patch check lines up with the frame's pixel grid (contract 8.4).
    public static func pixels(of image: CGImage, scaledTo output: PixelSize) throws(ScreenshotEncodingError)
        -> FramePixels
    {
        try render(image, to: output).pixels
    }

    static func attempts(for format: ImageFormat) -> [ImageEncoding] {
        switch format {
        case .jpeg: ContractConstants.jpegQualitySteps.map(ImageEncoding.jpeg)
        case .png: [.png]
        }
    }

    struct Bitmap {
        let image: CGImage
        let pixels: FramePixels
    }

    static func render(_ image: CGImage, to output: PixelSize) throws(ScreenshotEncodingError) -> Bitmap {
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard output.width >= 1, output.height >= 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: output.width, height: output.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: bitmapInfo)
        else { throw .renderFailed(output) }
        let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        context.interpolationQuality = .high
        // Transparent source pixels land on opaque black, never on whatever the buffer held.
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let drawn = context.makeImage(), let data = context.data else { throw .renderFailed(output) }

        let rowBytes = context.bytesPerRow
        let source = UnsafeRawBufferPointer(start: data, count: rowBytes * output.height)
        let count = output.width * output.height * FramePixels.bytesPerPixel
        let rgb = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            var next = 0
            for row in 0..<output.height {
                var offset = row * rowBytes
                for _ in 0..<output.width {
                    buffer[next] = source[offset]
                    buffer[next + 1] = source[offset + 1]
                    buffer[next + 2] = source[offset + 2]
                    next += 3
                    offset += 4
                }
            }
            initialized = count
        }
        guard let pixels = FramePixels(size: output, rgb: rgb) else { throw .renderFailed(output) }
        return Bitmap(image: drawn, pixels: pixels)
    }

    static func encode(_ image: CGImage, as encoding: ImageEncoding) throws(ScreenshotEncodingError) -> [UInt8] {
        let type: CFString
        var properties: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: false]
        switch encoding {
        case .jpeg(let quality):
            type = "public.jpeg" as CFString
            properties[kCGImageDestinationLossyCompressionQuality] = Double(quality.rawValue) / 100
        case .png:
            type = "public.png" as CFString
        }
        guard let data = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(data, type, 1, nil)
        else { throw .encodeFailed(encoding) }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), let start = CFDataGetBytePtr(data),
            let stripped = MetadataStripping.strip(
                Array(UnsafeBufferPointer(start: start, count: CFDataGetLength(data))), format: encoding.format)
        else { throw .encodeFailed(encoding) }
        return stripped
    }
}
