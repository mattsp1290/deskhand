public enum ScreenshotSizingError: Error, Hashable, Sendable {
    /// The caller's `max_long_edge` is outside 256 to 2576: `invalid_argument`.
    case maxLongEdgeOutOfRange(Int)
    /// The platform reported a source with a side below one pixel: a fault, not the caller's.
    case emptySource(PixelSize)

    /// The `invalid_argument` this error is, when it is the caller's.
    public var argumentError: ArgumentError? {
        guard case .maxLongEdgeOutOfRange = self else { return nil }
        let range = ContractConstants.minLongEdge...ContractConstants.maxLongEdge
        return ArgumentError(
            at: JSONPointer(["max_long_edge"]),
            "must be an integer from \(range.lowerBound) to \(range.upperBound)")
    }
}

/// The size of a returned screenshot (contract 7). The output never breaks `max_long_edge`,
/// `MAX_PIXELS` or `MAX_VISUAL_TOKENS` counted by patches, because a model provider refuses such an
/// image instead of shrinking it. The pixel cap implies the token cap for every size the rule
/// produces (contract 7 shows it); the loop checks both anyway, so a rounding slip cannot pass.
public struct ScreenshotSize: Hashable, Sendable {
    /// `ceil(w / 28) * ceil(h / 28)`: what a provider that counts by patches charges for `size`.
    public static func visualTokens(_ size: PixelSize) -> Int {
        let side = ContractConstants.visualTokenPatchSide
        return ((size.width + side - 1) / side) * ((size.height + side - 1) / side)
    }

    /// The frame pixel space.
    public let output: PixelSize
    /// The contract's `scale`, in (0, 1], reported as `downscale`. The output sides are floored from
    /// it, so `output` is not exactly `source * downscale`.
    public let downscale: Double

    public init(
        source: PixelSize, maxLongEdge: Int = ContractConstants.maxLongEdge
    ) throws(ScreenshotSizingError) {
        let maxPixels = ContractConstants.maxPixels
        guard (ContractConstants.minLongEdge...ContractConstants.maxLongEdge).contains(maxLongEdge) else {
            throw .maxLongEdgeOutOfRange(maxLongEdge)
        }
        guard source.width >= 1, source.height >= 1 else { throw .emptySource(source) }

        let width = Double(source.width)
        let height = Double(source.height)
        let scale = min(
            1, Double(maxLongEdge) / max(width, height), (Double(maxPixels) / (width * height)).squareRoot())
        var outWidth = max(1, Int((width * scale).rounded(.down)))
        var outHeight = max(1, Int((height * scale).rounded(.down)))
        while outWidth * outHeight > maxPixels || max(outWidth, outHeight) > maxLongEdge
            || Self.visualTokens(PixelSize(width: outWidth, height: outHeight)) > ContractConstants.maxVisualTokens
        {
            if outWidth >= outHeight { outWidth -= 1 } else { outHeight -= 1 }
        }
        output = PixelSize(width: outWidth, height: outHeight)
        downscale = scale
    }
}
