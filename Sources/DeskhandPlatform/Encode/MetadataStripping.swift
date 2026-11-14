import DeskhandCore

/// Rebuilds an encoded image from an allowlist of what decoding needs, so no metadata ImageIO writes
/// (it always adds an EXIF block, and a Photoshop block in JPEG, which no destination option turns off)
/// or might add in a later release is ever returned. Every segment or chunk is examined: one on the
/// allowlist is kept, metadata that decoding never needs is dropped, and anything else refuses the image.
enum MetadataStripping {
    enum Verdict: Equatable {
        case keep
        case drop
        case refuse
    }

    private static let jpegStart: [UInt8] = [0xFF, 0xD8]
    private static let startOfScan: UInt8 = 0xDA
    private static let endOfImage: UInt8 = 0xD9
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Critical chunks a truecolour image can have, and the ancillary ones that affect how it decodes.
    static let pngChunks: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "sRGB", "gAMA", "cHRM", "iCCP", "pHYs"]

    /// `nil` when `bytes` are not laid out as ImageIO writes the format, or carry something that is
    /// neither needed to decode nor safe to drop.
    static func strip(_ bytes: [UInt8], format: ImageFormat) -> [UInt8]? {
        switch format {
        case .jpeg: stripJPEG(bytes)
        case .png: stripPNG(bytes)
        }
    }

    /// `segment` is the whole marker segment, from its `0xFF`.
    static func jpegVerdict(marker: UInt8, segment: ArraySlice<UInt8>) -> Verdict {
        switch marker {
        // Frame headers SOF0-SOF15, except 0xC4 (DHT), 0xC8 (reserved) and 0xCC (DAC), which are not frames.
        case 0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF: .keep
        // DHT, DQT, DRI, SOS.
        case 0xC4, 0xDB, 0xDD, startOfScan: .keep
        case 0xE0: isJFIFWithoutThumbnail(segment) ? .keep : .drop
        // APP14 (Adobe) says whether the components are YCbCr; without it they would decode as the wrong colours.
        case 0xEE: .refuse
        // APP1-APP13, APP15 (EXIF, XMP, ICC, IPTC, Photoshop, thumbnails) and COM.
        case 0xE1...0xED, 0xEF, 0xFE: .drop
        default: .refuse
        }
    }

    /// A JFIF APP0 segment of exactly 16 bytes after the marker has no room for a thumbnail.
    private static func isJFIFWithoutThumbnail(_ segment: ArraySlice<UInt8>) -> Bool {
        let payload = Array(segment.dropFirst(4))
        return segment.count == 18 && payload.starts(with: Array("JFIF\0".utf8)) && payload[12] == 0 && payload[13] == 0
    }

    /// Walks every marker segment, including those between and after scans; entropy-coded data is copied as
    /// is. The image must end at its EOI marker.
    private static func stripJPEG(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.starts(with: jpegStart) else { return nil }
        var output = jpegStart
        output.reserveCapacity(bytes.count)
        var index = jpegStart.count
        while index + 2 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            if marker == endOfImage {
                return index + 2 == bytes.count ? output + [0xFF, endOfImage] : nil
            }
            guard index + 4 <= bytes.count else { return nil }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let end = index + 2 + length
            guard length >= 2, end <= bytes.count else { return nil }
            switch jpegVerdict(marker: marker, segment: bytes[index..<end]) {
            case .keep: output += bytes[index..<end]
            case .drop: break
            case .refuse: return nil
            }
            index = end
            if marker == startOfScan {
                guard let scanEnd = entropyCodedDataEnd(bytes, from: index) else { return nil }
                output += bytes[index..<scanEnd]
                index = scanEnd
            }
        }
        return nil
    }

    /// Where the entropy-coded data starting at `start` ends: the first `0xFF` that is neither a stuffed
    /// `0xFF 0x00` nor a restart marker. `nil` when the data runs to the end of the bytes.
    private static func entropyCodedDataEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0xFF {
                let next = bytes[index + 1]
                guard next == 0x00 || (0xD0...0xD7).contains(next) else { return index }
                index += 2
            } else {
                index += 1
            }
        }
        return nil
    }

    /// Ancillary chunks (lower-case first letter) are never needed to decode, so an unknown one is
    /// dropped; an unknown critical chunk refuses the image.
    static func pngVerdict(type: String) -> Verdict {
        if pngChunks.contains(type) { return .keep }
        return type.utf8.first.map { $0 & 0x20 != 0 } == true ? .drop : .refuse
    }

    private static func stripPNG(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.starts(with: pngSignature) else { return nil }
        var output = pngSignature
        output.reserveCapacity(bytes.count)
        var index = pngSignature.count
        while index + 12 <= bytes.count {
            let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
            let typeBytes = bytes[index + 4..<index + 8]
            let end = index + 12 + length
            guard end <= bytes.count, typeBytes.allSatisfy(isASCIILetter) else { return nil }
            let type = String(decoding: typeBytes, as: UTF8.self)
            guard index > pngSignature.count || type == "IHDR" else { return nil }
            switch pngVerdict(type: type) {
            case .keep: output += bytes[index..<end]
            case .drop: break
            case .refuse: return nil
            }
            index = end
            if type == "IEND" { return index == bytes.count ? output : nil }
        }
        return nil
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }
}
