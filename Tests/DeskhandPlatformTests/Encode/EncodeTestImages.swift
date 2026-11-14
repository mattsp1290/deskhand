import CoreGraphics
import Foundation
import ImageIO

/// Synthetic captures: 8-bit RGBX buffers whose first row is the top of the image.
enum EncodeTestImages {
    typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    static func image(
        width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
        pixel: (_ x: Int, _ y: Int) -> RGB
    ) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = color.r
                bytes[offset + 1] = color.g
                bytes[offset + 2] = color.b
            }
        }
        return image(width: width, height: height, space: space, bytes: bytes)
    }

    /// Cheap at screen sizes, where a per-pixel closure is slow in debug builds.
    static func gray(width: Int, height: Int, level: UInt8) -> CGImage {
        image(
            width: width, height: height, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bytes: [UInt8](repeating: level, count: width * height * 4))
    }

    /// Uniform random bytes from a fixed seed: incompressible, so encoded sizes are large and stable.
    static func noise(width: Int, height: Int, seed: UInt64 = 0x5EED) -> CGImage {
        var generator = SplitMix64(state: seed)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var index = 0
        while index < bytes.count {
            let word = generator.next()
            for shift in 0..<8 where index + shift < bytes.count {
                bytes[index + shift] = UInt8(truncatingIfNeeded: word >> (8 * UInt64(shift)))
            }
            index += 8
        }
        return image(width: width, height: height, space: CGColorSpace(name: CGColorSpace.sRGB)!, bytes: bytes)
    }

    private static func image(width: Int, height: Int, space: CGColorSpace, bytes: [UInt8]) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// What ImageIO reads back from encoded bytes.
    static func decode(_ bytes: [UInt8]) -> (source: CGImageSource, image: CGImage)? {
        guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (source, image)
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
