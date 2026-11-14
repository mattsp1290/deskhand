import CoreGraphics
import DeskhandCore
import Testing

@testable import DeskhandPlatform

private let image = EncodeTestImages.image(width: 48, height: 32) { x, y in (UInt8(x * 5), UInt8(y * 7), 40) }

private func encoded(_ format: ImageFormat) throws -> [UInt8] {
    try ScreenshotEncoder.encode(image, format: format, maxLongEdge: 2576, maxImageBytes: .max).bytes
}

private func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let length = payload.count + 2
    return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
}

/// The CRC is not checked, so it is left zero.
private func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
    let length = UInt32(data.count)
    return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) } + Array(type.utf8) + data + [0, 0, 0, 0]
}

private let jfifWithThumbnail = segment(
    0xE0, Array("JFIF\0".utf8) + [1, 1, 0, 0, 72, 0, 72, 1, 1] + [255, 0, 0])

@Suite struct MetadataStrippingTests {
    @Test(arguments: [
        (UInt8(0xC0), MetadataStripping.Verdict.keep), (0xC2, .keep), (0xC4, .keep), (0xDB, .keep), (0xDD, .keep),
        (0xDA, .keep), (0xE1, .drop), (0xE2, .drop), (0xED, .drop), (0xEF, .drop), (0xFE, .drop), (0xEE, .refuse),
        (0xC8, .refuse), (0xCC, .refuse), (0xDC, .refuse), (0xF0, .refuse), (0xD8, .refuse), (0xD0, .refuse),
        (0xFF, .refuse),
    ])
    func jpegMarkersAreKeptDroppedOrRefused(marker: UInt8, verdict: MetadataStripping.Verdict) {
        #expect(MetadataStripping.jpegVerdict(marker: marker, segment: segment(marker, [0, 0])[...]) == verdict)
    }

    @Test func jfifIsKeptOnlyWithoutAThumbnail() throws {
        let clean = try encoded(.jpeg)
        let app0 = clean[2..<20]
        try #require(Array(app0.prefix(4)) == [0xFF, 0xE0, 0x00, 0x10])
        #expect(MetadataStripping.jpegVerdict(marker: 0xE0, segment: app0) == .keep)
        #expect(MetadataStripping.jpegVerdict(marker: 0xE0, segment: jfifWithThumbnail[...]) == .drop)
        let jfxx = segment(0xE0, Array("JFXX\0".utf8) + [0x10, 1, 2, 3])
        #expect(MetadataStripping.jpegVerdict(marker: 0xE0, segment: jfxx[...]) == .drop)

        let swapped = Array(clean.prefix(2)) + jfifWithThumbnail + Array(clean.dropFirst(20))
        #expect(MetadataStripping.strip(swapped, format: .jpeg) == Array(clean.prefix(2)) + Array(clean.dropFirst(20)))
    }

    /// Metadata before the frame, between the scan and EOI, or in a segment no current ImageIO writes
    /// is all dropped, leaving exactly the clean image.
    @Test func jpegMetadataIsDroppedWhereverItIs() throws {
        let clean = try encoded(.jpeg)
        try #require(clean.suffix(2) == [0xFF, 0xD9])
        let exif = segment(0xE1, Array("Exif\0\0".utf8) + [1, 2, 3])
        let icc = segment(0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1])
        let comment = segment(0xFE, Array("secret".utf8))
        let app15 = segment(0xEF, [9, 9])
        var tagged = Array(clean.prefix(20))
        tagged += exif
        tagged += icc
        tagged += clean[20..<(clean.count - 2)]
        tagged += comment
        tagged += app15
        tagged += [0xFF, 0xD9]
        #expect(MetadataStripping.strip(tagged, format: .jpeg) == clean)
    }

    @Test func jpegThatCannotBeVouchedForIsRefused() throws {
        let clean = try encoded(.jpeg)
        let head = Array(clean.prefix(20))
        let rest = Array(clean.dropFirst(20))
        let adobe = segment(0xEE, Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 0])
        #expect(MetadataStripping.strip(head + adobe + rest, format: .jpeg) == nil)
        #expect(MetadataStripping.strip(head + segment(0xCC, [0, 0]) + rest, format: .jpeg) == nil)
        #expect(MetadataStripping.strip(clean + [0x00], format: .jpeg) == nil)
        #expect(MetadataStripping.strip(clean + [0xFF, 0xD9], format: .jpeg) == nil)
        #expect(MetadataStripping.strip(Array(clean.dropLast(2)), format: .jpeg) == nil)
    }

    @Test(arguments: [
        ("IHDR", MetadataStripping.Verdict.keep), ("IDAT", .keep), ("IEND", .keep), ("PLTE", .keep), ("sRGB", .keep),
        ("iCCP", .keep), ("pHYs", .keep), ("gAMA", .keep), ("cHRM", .keep), ("eXIf", .drop), ("tEXt", .drop),
        ("iTXt", .drop), ("zTXt", .drop), ("tIME", .drop), ("vpAg", .drop), ("ABCD", .refuse), ("Exif", .refuse),
    ])
    func pngChunksAreKeptDroppedOrRefused(type: String, verdict: MetadataStripping.Verdict) {
        #expect(MetadataStripping.pngVerdict(type: type) == verdict)
    }

    @Test func pngAncillaryChunksNotKeptAreDropped() throws {
        let clean = try encoded(.png)
        let afterHeader = 8 + 25
        try #require(String(decoding: clean[12..<16], as: UTF8.self) == "IHDR")
        var tagged = Array(clean.prefix(afterHeader))
        tagged += chunk("tEXt", Array("Author\0me".utf8))
        tagged += chunk("eXIf", [1, 2])
        tagged += chunk("tIME", [7, 234, 1, 1, 0, 0, 0])
        tagged += chunk("vpAg", [0])
        tagged += clean[afterHeader..<(clean.count - 12)]
        tagged += chunk("zTXt", Array("k\0\0".utf8))
        tagged += chunk("iTXt", Array("k\0\0\0\0\0".utf8))
        tagged += clean.suffix(12)
        #expect(MetadataStripping.strip(tagged, format: .png) == clean)
        #expect(Set(try #require(chunkTypes(clean))).isSubset(of: MetadataStripping.pngChunks))
    }

    @Test func pngThatCannotBeVouchedForIsRefused() throws {
        let clean = try encoded(.png)
        let head = Array(clean.prefix(33))
        let rest = Array(clean.dropFirst(33))
        #expect(MetadataStripping.strip(head + chunk("ABCD", [1]) + rest, format: .png) == nil)
        #expect(MetadataStripping.strip(head + chunk("a1cd", [1]) + rest, format: .png) == nil)
        #expect(MetadataStripping.strip(clean + [0], format: .png) == nil)
        let srgbFirst = Array(clean.prefix(8)) + chunk("sRGB", [0]) + Array(clean.dropFirst(8))
        #expect(MetadataStripping.strip(srgbFirst, format: .png) == nil)
    }

    private func chunkTypes(_ bytes: [UInt8]) -> [String]? {
        var types: [String] = []
        var index = 8
        while index + 12 <= bytes.count {
            let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
            types.append(String(decoding: bytes[index + 4..<index + 8], as: UTF8.self))
            index += 12 + length
        }
        return index == bytes.count ? types : nil
    }
}
