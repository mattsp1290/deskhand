import DeskhandCore

/// Removes the metadata ImageIO always writes, which no destination option turns off: an EXIF block
/// (pixel dimensions and colour space) in both formats and a Photoshop resolution block in JPEG.
/// Everything that affects decoding (JFIF, ICC, Adobe colour transform, PNG `sRGB`/`iCCP`) is kept.
enum MetadataStripping {
    /// APP1 (EXIF, XMP, EXIF thumbnails), APP13 (IPTC, Photoshop) and COM.
    static let jpegMarkers: Set<UInt8> = [0xE1, 0xED, 0xFE]
    static let pngChunks: Set<String> = ["eXIf", "tEXt", "iTXt", "zTXt", "tIME"]

    private static let jpegStart: [UInt8] = [0xFF, 0xD8]
    private static let startOfScan: UInt8 = 0xDA
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// `nil` when `bytes` are not laid out as ImageIO writes the format, so nothing unexamined is
    /// ever returned.
    static func strip(_ bytes: [UInt8], format: ImageFormat) -> [UInt8]? {
        switch format {
        case .jpeg: stripJPEG(bytes)
        case .png: stripPNG(bytes)
        }
    }

    /// Walks the marker segments up to the start of scan; the entropy-coded data after it is copied as is.
    private static func stripJPEG(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.starts(with: jpegStart) else { return nil }
        var output = jpegStart
        output.reserveCapacity(bytes.count)
        var index = jpegStart.count
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            if marker == startOfScan {
                output += bytes[index...]
                return output
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let end = index + 2 + length
            guard length >= 2, end <= bytes.count else { return nil }
            if !jpegMarkers.contains(marker) { output += bytes[index..<end] }
            index = end
        }
        return nil
    }

    private static func stripPNG(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.starts(with: pngSignature) else { return nil }
        var output = pngSignature
        output.reserveCapacity(bytes.count)
        var index = pngSignature.count
        while index + 12 <= bytes.count {
            let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[index + 4..<index + 8], as: UTF8.self)
            let end = index + 12 + length
            guard end <= bytes.count else { return nil }
            if !pngChunks.contains(type) { output += bytes[index..<end] }
            index = end
            if type == "IEND" { return index == bytes.count ? output : nil }
        }
        return nil
    }
}
