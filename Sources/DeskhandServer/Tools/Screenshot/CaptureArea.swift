import DeskhandCore

struct CaptureArea: Hashable, Sendable {
    let display: DisplayInfo
    let captureRect: GlobalRect
    let sourcePixelSize: PixelSize

    enum Failure: Error, Hashable, Sendable {
        case invalidArgument(ArgumentError)
        case fault(PlatformFault)
    }

    private static let gridTolerance = 1e-6

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

    private static func alignedRange(from offset: Double, length: Double, scale: Double) -> Range<Int> {
        let lower = Int((offset * scale + gridTolerance).rounded(.down))
        let upper = Int(((offset + length) * scale - gridTolerance).rounded(.up))
        return lower..<max(upper, lower + 1)
    }
}
