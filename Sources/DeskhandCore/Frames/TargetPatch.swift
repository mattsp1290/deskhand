/// A frame's output pixels as captured, before encoding: 8-bit sRGB, no alpha, row-major, three
/// bytes per pixel (contract 7, 8.4). deskhand keeps them for each live frame.
public struct FramePixels: Equatable, Sendable {
    public static let bytesPerPixel = 3

    public let size: PixelSize
    public let rgb: [UInt8]

    /// `nil` unless both sides are at least 1 and `rgb` holds exactly `width * height * 3` bytes.
    public init?(size: PixelSize, rgb: [UInt8]) {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let (pixels, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        let (bytes, overflowBytes) = pixels.multipliedReportingOverflow(by: Self.bytesPerPixel)
        guard !overflow, !overflowBytes, bytes == rgb.count else { return nil }
        self.size = size
        self.rgb = rgb
    }

    fileprivate func offset(x: Int, y: Int) -> Int { (y * size.width + x) * Self.bytesPerPixel }
}

/// What a target-patch comparison found. Only `unchanged` lets a `pointer` call proceed.
public enum PatchVerdict: Hashable, Sendable {
    case unchanged, changed
    /// The patch could not be compared, for example because capture failed. Refused like `changed`.
    case unknown
}

/// The pixels around one pointer target that must look as they did in the frame (contract 8.4).
public struct TargetPatch: Hashable, Sendable {
    static let changedFractionDenominator = 50

    /// The target the patch was cut around.
    public let center: FramePoint
    /// `[x0, x1)` in frame pixels.
    public let columns: Range<Int>
    /// `[y0, y1)` in frame pixels.
    public let rows: Range<Int>
    /// What deskhand captures again, at least, in global points.
    public let globalRect: GlobalRect
    /// The frame's output pixel size.
    public let frameSize: PixelSize

    public var pixelCount: Int { columns.count * rows.count }

    /// Compares the patch in the frame's pixels with a new capture scaled exactly as the frame was.
    /// `current` is either the whole frame recaptured (`frameSize`) or just the patch
    /// (`columns.count` by `rows.count`); any other size, or `original` not of `frameSize`, is `unknown`.
    public func compare(original: FramePixels, current: FramePixels) -> PatchVerdict {
        guard original.size == frameSize else { return .unknown }
        let origin: (x: Int, y: Int)
        switch current.size {
        case frameSize: origin = (0, 0)
        case PixelSize(width: columns.count, height: rows.count): origin = (columns.lowerBound, rows.lowerBound)
        default: return .unknown
        }
        let tolerance = ContractConstants.patchChannelTolerance
        var changed = 0
        for y in rows {
            for x in columns {
                let before = original.offset(x: x, y: y)
                let after = current.offset(x: x - origin.x, y: y - origin.y)
                for channel in 0..<FramePixels.bytesPerPixel
                where abs(Int(original.rgb[before + channel]) - Int(current.rgb[after + channel])) > tolerance {
                    changed += 1
                    break
                }
            }
        }
        return changed * Self.changedFractionDenominator > pixelCount ? .changed : .unchanged
    }
}
