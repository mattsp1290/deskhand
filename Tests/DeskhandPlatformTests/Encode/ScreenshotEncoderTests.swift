import CoreGraphics
import DeskhandCore
import ImageIO
import Testing

@testable import DeskhandPlatform

private let unlimited = Int.max

@Suite struct ScreenshotEncoderSizingTests {
    @Test(arguments: [
        (PixelSize(width: 3456, height: 2234), 2576),
        (PixelSize(width: 5120, height: 2880), 2576),
        (PixelSize(width: 2560, height: 1440), 2576),
        (PixelSize(width: 3456, height: 2234), 1568),
        (PixelSize(width: 800, height: 600), 256),
        (PixelSize(width: 300, height: 200), 2576),
        (PixelSize(width: 4000, height: 3), 256),
        (PixelSize(width: 1, height: 1), 2576),
    ])
    func outputSizeIsScreenshotSize(source: PixelSize, maxLongEdge: Int) throws {
        let image = EncodeTestImages.gray(width: source.width, height: source.height, level: 128)
        let expected = try ScreenshotSize(source: source, maxLongEdge: maxLongEdge)

        let result = try ScreenshotEncoder.encode(
            image, format: .jpeg, maxLongEdge: maxLongEdge, maxImageBytes: unlimited)

        #expect(result.size == expected)
        #expect(result.outputPixelSize == expected.output)
        #expect(result.downscale == expected.downscale)
        #expect(result.pixels.size == expected.output)
        let decoded = try #require(EncodeTestImages.decode(result.bytes))
        #expect(PixelSize(width: decoded.image.width, height: decoded.image.height) == expected.output)
    }

    @Test(arguments: [100, 255, 2577])
    func maxLongEdgeOutOfRangeIsInvalidArgument(maxLongEdge: Int) {
        let image = EncodeTestImages.gray(width: 64, height: 64, level: 0)
        let error = #expect(throws: ScreenshotEncodingError.self) {
            try ScreenshotEncoder.encode(image, format: .png, maxLongEdge: maxLongEdge, maxImageBytes: unlimited)
        }
        #expect(error == .sizing(.maxLongEdgeOutOfRange(maxLongEdge)))
        #expect(error?.reason == .invalidArgument(JSONPointer(["max_long_edge"])))
    }
}

@Suite struct ScreenshotEncoderFormatTests {
    private static let noise = EncodeTestImages.noise(width: 512, height: 384)

    private static func jpegSizes() throws -> [JPEGQuality: Int] {
        let bitmap = try ScreenshotEncoder.render(noise, to: PixelSize(width: 512, height: 384))
        var sizes: [JPEGQuality: Int] = [:]
        for quality in JPEGQuality.allCases {
            sizes[quality] = try ScreenshotEncoder.encode(bitmap.image, as: .jpeg(quality)).count
        }
        return sizes
    }

    @Test func jpegDefaultsToQuality85() throws {
        let result = try ScreenshotEncoder.encode(
            Self.noise, format: .jpeg, maxLongEdge: 2576, maxImageBytes: unlimited)
        #expect(result.encoding == .jpeg(.q85))
        #expect(result.jpegQuality == .q85)
        #expect(result.mimeType == "image/jpeg")
        #expect(result.imageBytes == result.bytes.count)
        #expect(Array(result.bytes.prefix(3)) == [0xFF, 0xD8, 0xFF])
    }

    @Test(arguments: [JPEGQuality.q75, .q65, .q60])
    func jpegStepsDownToTheFirstQualityThatFits(quality: JPEGQuality) throws {
        let sizes = try Self.jpegSizes()
        let ordered = JPEGQuality.allCases.map { sizes[$0]! }
        try #require(ordered == ordered.sorted(by: >) && Set(ordered).count == ordered.count)
        let limit = sizes[quality]!

        let result = try ScreenshotEncoder.encode(Self.noise, format: .jpeg, maxLongEdge: 2576, maxImageBytes: limit)

        #expect(result.encoding == .jpeg(quality))
        #expect(result.imageBytes == limit)
        #expect(result.imageBytes <= limit)
    }

    @Test func jpegOverLimitAtQuality60IsImageTooLarge() throws {
        let q60 = try #require(try Self.jpegSizes()[.q60])
        let error = #expect(throws: ScreenshotEncodingError.self) {
            try ScreenshotEncoder.encode(Self.noise, format: .jpeg, maxLongEdge: 2576, maxImageBytes: q60 - 1)
        }
        #expect(error == .imageTooLarge(imageBytes: q60, maxImageBytes: q60 - 1))
        #expect(error?.reason == .imageTooLarge(imageBytes: q60))
    }

    @Test func pngIsEncodedOnceAndNeverSwitchesFormat() throws {
        let fits = try ScreenshotEncoder.encode(Self.noise, format: .png, maxLongEdge: 2576, maxImageBytes: unlimited)
        #expect(fits.encoding == .png)
        #expect(fits.jpegQuality == nil)
        #expect(fits.mimeType == "image/png")
        #expect(Array(fits.bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let atLimit = try ScreenshotEncoder.encode(
            Self.noise, format: .png, maxLongEdge: 2576, maxImageBytes: fits.imageBytes)
        #expect(atLimit.bytes == fits.bytes)

        let error = #expect(throws: ScreenshotEncodingError.self) {
            try ScreenshotEncoder.encode(
                Self.noise, format: .png, maxLongEdge: 2576, maxImageBytes: fits.imageBytes - 1)
        }
        #expect(error == .imageTooLarge(imageBytes: fits.imageBytes, maxImageBytes: fits.imageBytes - 1))
        #expect(error?.reason == .imageTooLarge(imageBytes: fits.imageBytes))
    }

    @Test(arguments: ImageFormat.allCases)
    func encodingIsDeterministic(format: ImageFormat) throws {
        let first = try ScreenshotEncoder.encode(Self.noise, format: format, maxLongEdge: 300, maxImageBytes: unlimited)
        let second = try ScreenshotEncoder.encode(
            Self.noise, format: format, maxLongEdge: 300, maxImageBytes: unlimited)
        #expect(first.bytes == second.bytes)
        #expect(first.pixels == second.pixels)
    }
}

@Suite struct ScreenshotEncoderMetadataTests {
    private static let image = EncodeTestImages.image(width: 96, height: 64) { x, y in
        (UInt8(x * 2), UInt8(y * 3), 77)
    }

    @Test(arguments: ImageFormat.allCases)
    func noMetadataDictionariesOrThumbnails(format: ImageFormat) throws {
        let result = try ScreenshotEncoder.encode(
            Self.image, format: format, maxLongEdge: 2576, maxImageBytes: unlimited)
        let decoded = try #require(EncodeTestImages.decode(result.bytes))

        #expect(CGImageSourceGetCount(decoded.source) == 1)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(decoded.source, 0, nil) as? [CFString: Any])
        for key in [
            kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary, kCGImagePropertyExifAuxDictionary,
        ] {
            #expect(properties[key] == nil, "unexpected \(key)")
        }
        #expect(properties[kCGImagePropertyFileContentsDictionary] == nil)
        let tags = CGImageSourceCopyMetadataAtIndex(decoded.source, 0, nil).flatMap(CGImageMetadataCopyTags)
        #expect((tags as? [CGImageMetadataTag] ?? []).isEmpty)
        let redrawn = try ScreenshotEncoder.pixels(of: decoded.image, scaledTo: result.outputPixelSize)
        #expect(redrawn.size == result.pixels.size)
    }

    @Test func jpegHasNoAPP1APP13OrCommentSegments() throws {
        let result = try ScreenshotEncoder.encode(
            Self.image, format: .jpeg, maxLongEdge: 2576, maxImageBytes: unlimited)
        let markers = try #require(Self.jpegMarkers(result.bytes))
        // APP1 carries EXIF (and its thumbnail) and XMP, APP13 IPTC, COM free text.
        #expect(markers.isDisjoint(with: [0xE1, 0xED, 0xFE]), "markers: \(markers)")
        #expect(markers.contains(0xC0) || markers.contains(0xC2))
    }

    @Test(arguments: ImageFormat.allCases)
    func strippingRefusesBytesItCannotWalk(format: ImageFormat) throws {
        let result = try ScreenshotEncoder.encode(
            Self.image, format: format, maxLongEdge: 2576, maxImageBytes: unlimited)
        #expect(MetadataStripping.strip(Array(result.bytes.prefix(40)), format: format) == nil)
        #expect(MetadataStripping.strip([0, 1, 2, 3], format: format) == nil)
        #expect(MetadataStripping.strip(result.bytes, format: format) == result.bytes)
    }

    @Test func pngIsEightBitRGBWithoutTextChunks() throws {
        let result = try ScreenshotEncoder.encode(Self.image, format: .png, maxLongEdge: 2576, maxImageBytes: unlimited)
        let chunks = try #require(Self.pngChunks(result.bytes))
        let header = try #require(chunks.first)
        #expect(header.type == "IHDR")
        // Bit depth 8, colour type 2: truecolour without alpha.
        #expect(header.data[8] == 8)
        #expect(header.data[9] == 2)
        let types = Set(chunks.map(\.type))
        #expect(types.isDisjoint(with: ["eXIf", "tEXt", "iTXt", "zTXt", "tIME"]), "chunks: \(chunks.map(\.type))")
    }

    private static func jpegMarkers(_ bytes: [UInt8]) -> Set<UInt8>? {
        guard bytes.starts(with: [0xFF, 0xD8]) else { return nil }
        var markers: Set<UInt8> = []
        var index = 2
        while index + 3 < bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            if marker == 0xDA { return markers }
            markers.insert(marker)
            index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
        }
        return nil
    }

    private static func pngChunks(_ bytes: [UInt8]) -> [(type: String, data: [UInt8])]? {
        guard bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        var chunks: [(type: String, data: [UInt8])] = []
        var index = 8
        while index + 8 <= bytes.count {
            let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[index + 4..<index + 8], as: UTF8.self)
            guard index + 12 + length <= bytes.count else { return nil }
            chunks.append((type, Array(bytes[index + 8..<index + 8 + length])))
            index += 12 + length
            if type == "IEND" { return chunks }
        }
        return nil
    }
}

@Suite struct ScreenshotEncoderPixelTests {
    private static let red: EncodeTestImages.RGB = (255, 0, 0)
    private static let green: EncodeTestImages.RGB = (0, 255, 0)
    private static let blue: EncodeTestImages.RGB = (0, 0, 255)
    private static let white: EncodeTestImages.RGB = (255, 255, 255)

    private static func quadrants(width: Int, height: Int) -> CGImage {
        EncodeTestImages.image(width: width, height: height) { x, y in
            switch (x < width / 2, y < height / 2) {
            case (true, true): red
            case (false, true): green
            case (true, false): blue
            case (false, false): white
            }
        }
    }

    private static func rgb(_ pixels: FramePixels, x: Int, y: Int) -> [UInt8] {
        let offset = (y * pixels.size.width + x) * FramePixels.bytesPerPixel
        return Array(pixels.rgb[offset..<offset + 3])
    }

    private static func bytes(_ color: EncodeTestImages.RGB) -> [UInt8] { [color.r, color.g, color.b] }

    @Test func unscaledPixelsMatchTheSourceRowZeroAtTheTop() throws {
        let result = try ScreenshotEncoder.encode(
            Self.quadrants(width: 40, height: 20), format: .png, maxLongEdge: 2576, maxImageBytes: unlimited)

        #expect(result.pixels.size == PixelSize(width: 40, height: 20))
        #expect(result.pixels.rgb.count == 40 * 20 * 3)
        #expect(result.downscale == 1)
        #expect(Self.rgb(result.pixels, x: 0, y: 0) == Self.bytes(Self.red))
        #expect(Self.rgb(result.pixels, x: 39, y: 0) == Self.bytes(Self.green))
        #expect(Self.rgb(result.pixels, x: 0, y: 19) == Self.bytes(Self.blue))
        #expect(Self.rgb(result.pixels, x: 39, y: 19) == Self.bytes(Self.white))
        #expect(Self.rgb(result.pixels, x: 19, y: 9) == Self.bytes(Self.red))
        #expect(Self.rgb(result.pixels, x: 20, y: 10) == Self.bytes(Self.white))
    }

    @Test func pngDecodesToTheFramePixels() throws {
        let result = try ScreenshotEncoder.encode(
            Self.quadrants(width: 40, height: 20), format: .png, maxLongEdge: 2576, maxImageBytes: unlimited)
        let decoded = try #require(EncodeTestImages.decode(result.bytes))
        let redrawn = try ScreenshotEncoder.pixels(of: decoded.image, scaledTo: result.outputPixelSize)
        #expect(redrawn == result.pixels)
    }

    @Test func downscaledQuadrantsKeepTheirColours() throws {
        let result = try ScreenshotEncoder.encode(
            Self.quadrants(width: 1024, height: 512), format: .jpeg, maxLongEdge: 256, maxImageBytes: unlimited)

        #expect(result.pixels.size == PixelSize(width: 256, height: 128))
        #expect(Self.rgb(result.pixels, x: 64, y: 32) == Self.bytes(Self.red))
        #expect(Self.rgb(result.pixels, x: 192, y: 32) == Self.bytes(Self.green))
        #expect(Self.rgb(result.pixels, x: 64, y: 96) == Self.bytes(Self.blue))
        #expect(Self.rgb(result.pixels, x: 192, y: 96) == Self.bytes(Self.white))
    }

    @Test func pixelsOfMatchesTheEncodersPixels() throws {
        let image = Self.quadrants(width: 1000, height: 700)
        let result = try ScreenshotEncoder.encode(image, format: .jpeg, maxLongEdge: 512, maxImageBytes: unlimited)
        #expect(try ScreenshotEncoder.pixels(of: image, scaledTo: result.outputPixelSize) == result.pixels)
    }

    @Test func displayP3SourceIsConvertedToSRGB() throws {
        // sRGB pure red expressed in Display P3 is about (0.9175, 0.2003, 0.1386).
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let image = EncodeTestImages.image(width: 8, height: 8, space: p3) { _, _ in (234, 51, 35) }

        let result = try ScreenshotEncoder.encode(image, format: .png, maxLongEdge: 2576, maxImageBytes: unlimited)

        let pixel = Self.rgb(result.pixels, x: 4, y: 4)
        #expect(pixel[0] >= 250)
        #expect(pixel[1] <= 6)
        #expect(pixel[2] <= 6)
    }
}
