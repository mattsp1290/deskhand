import DeskhandCore

/// What a `screenshot` captures: the display and the rectangle, aligned outward to whole native
/// pixels (contract 6.3).
struct CaptureArea: Hashable, Sendable {
    let display: DisplayInfo
    /// Global points. The origin may be negative.
    let captureRect: GlobalRect
    /// Native pixels of `captureRect`.
    let sourcePixelSize: PixelSize

    enum Failure: Error, Hashable, Sendable {
        /// `invalid_argument`: a `display_id` that is not active, or a region not inside its display.
        case invalidArgument(ArgumentError)
        /// The configuration has no main display, or a display whose size cannot be captured.
        case fault(PlatformFault)
    }

    /// Native pixels are this much off a whole number at most and still count as whole, so the
    /// rounding of points to pixels never adds a pixel to an edge that lies on the grid.
    private static let gridTolerance = 1e-6

    /// The area `displayID` and `region` name in `configuration`.
    static func resolve(displayID: DisplayID?, region: GlobalRect?, in configuration: DisplayConfiguration)
        throws(Failure) -> CaptureArea
    {
        let display: DisplayInfo
        if let displayID {
            guard let named = configuration.display(displayID) else {
                throw .invalidArgument(ArgumentError(at: JSONPointer(["display_id"]), "is not an active display"))
            }
            display = named
        } else {
            guard let main = configuration.main else { throw .fault(PlatformFault("No main display is active.")) }
            display = main
        }
        let bounds = display.bounds
        let pixels = display.pixelSize
        guard bounds.width > 0, bounds.height > 0, pixels.width >= 1, pixels.height >= 1 else {
            throw .fault(PlatformFault("Display \(display.displayID) reports an empty size."))
        }
        guard let region else { return CaptureArea(display: display, captureRect: bounds, sourcePixelSize: pixels) }
        guard region.x >= bounds.x, region.y >= bounds.y, region.x + region.width <= bounds.x + bounds.width,
            region.y + region.height <= bounds.y + bounds.height
        else {
            throw .invalidArgument(
                ArgumentError(at: JSONPointer(["region"]), "must lie entirely inside the bounds of the display"))
        }
        // Native pixels per point along each axis.
        let sx = Double(pixels.width) / bounds.width
        let sy = Double(pixels.height) / bounds.height
        let columns = alignedRange(from: region.x - bounds.x, length: region.width, scale: sx)
        let rows = alignedRange(from: region.y - bounds.y, length: region.height, scale: sy)
        let first = (x: max(0, columns.lowerBound), y: max(0, rows.lowerBound))
        let end = (x: min(pixels.width, columns.upperBound), y: min(pixels.height, rows.upperBound))
        let rect = GlobalRect(
            x: bounds.x + Double(first.x) / sx, y: bounds.y + Double(first.y) / sy,
            width: Double(end.x - first.x) / sx, height: Double(end.y - first.y) / sy)
        return CaptureArea(
            display: display, captureRect: rect,
            sourcePixelSize: PixelSize(width: end.x - first.x, height: end.y - first.y))
    }

    /// The native pixels that cover `[offset, offset + length)` points from the display's origin,
    /// widened to whole pixels. At least one pixel wide, since the region is at least one point.
    private static func alignedRange(from offset: Double, length: Double, scale: Double) -> Range<Int> {
        let lower = Int((offset * scale + gridTolerance).rounded(.down))
        let upper = Int(((offset + length) * scale - gridTolerance).rounded(.up))
        return lower..<max(upper, lower + 1)
    }
}
