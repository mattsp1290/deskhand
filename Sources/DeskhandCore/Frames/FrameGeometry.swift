/// How one frame's pixels relate to global points (contract 8.1, 8.2). A frame pixel `(x, y)` covers
/// the cell of `captureRect` whose centre is `captureRect.origin + (x + 0.5) * captureRect.size / outputPixelSize`.
public struct FrameGeometry: Hashable, Sendable {
    /// Global points; the origin may be negative.
    public let captureRect: GlobalRect
    /// The frame pixel space.
    public let outputPixelSize: PixelSize
    /// The bounds of the frame's display, in global points. Mapped targets are clamped to them.
    public let displayBounds: GlobalRect

    /// `nil` unless both rectangles are finite with positive sides and the output has at least one pixel.
    public init?(captureRect: GlobalRect, outputPixelSize: PixelSize, displayBounds: GlobalRect) {
        guard captureRect.isUsable, displayBounds.isUsable, outputPixelSize.width >= 1, outputPixelSize.height >= 1
        else { return nil }
        self.captureRect = captureRect
        self.outputPixelSize = outputPixelSize
        self.displayBounds = displayBounds
    }

    /// Global points per frame pixel along each axis: how scroll deltas convert.
    public var pointsPerPixel: (x: Double, y: Double) {
        (captureRect.width / Double(outputPixelSize.width), captureRect.height / Double(outputPixelSize.height))
    }

    /// `0 <= x < W` and `0 <= y < H`.
    public func contains(_ point: FramePoint) -> Bool {
        (0..<outputPixelSize.width).contains(point.x) && (0..<outputPixelSize.height).contains(point.y)
    }

    /// The `out_of_frame` refusal for an action's points, naming the first point outside, or `nil`.
    public func outOfFrame(_ points: [FramePoint]) -> ToolErrorReason? {
        guard let index = points.firstIndex(where: { !contains($0) }) else { return nil }
        return .outOfFrame(pointIndex: index, outputPixelSize: outputPixelSize)
    }

    /// The centre of the named pixel in global points, clamped to the display's bounds, or `nil` for
    /// a point outside the frame: the pointer never goes where the caller never saw.
    public func globalPoint(for point: FramePoint) -> GlobalPoint? {
        guard contains(point) else { return nil }
        let x = captureRect.x + (Double(point.x) + 0.5) * captureRect.width / Double(outputPixelSize.width)
        let y = captureRect.y + (Double(point.y) + 0.5) * captureRect.height / Double(outputPixelSize.height)
        return GlobalPoint(
            x: x.clamped(from: displayBounds.x, below: displayBounds.x + displayBounds.width),
            y: y.clamped(from: displayBounds.y, below: displayBounds.y + displayBounds.height))
    }

    /// The frame pixel containing a global point, or `nil` when it lies outside the frame. This is how
    /// `pointer_position` is reported.
    public func framePoint(for point: GlobalPoint) -> FramePoint? {
        let x = ((point.x - captureRect.x) * Double(outputPixelSize.width) / captureRect.width).rounded(.down)
        let y = ((point.y - captureRect.y) * Double(outputPixelSize.height) / captureRect.height).rounded(.down)
        guard x >= 0, y >= 0, x < Double(outputPixelSize.width), y < Double(outputPixelSize.height) else {
            return nil
        }
        return FramePoint(x: Int(x), y: Int(y))
    }

    /// A scroll delta in frame pixels converted to global points with the frame's ratio.
    public func globalDelta(dx: Int, dy: Int) -> (dx: Double, dy: Double) {
        let ratio = pointsPerPixel
        return (Double(dx) * ratio.x, Double(dy) * ratio.y)
    }

    /// The patch checked around a target (contract 8.4), or `nil` for a point outside the frame.
    public func targetPatch(around point: FramePoint) -> TargetPatch? {
        guard contains(point) else { return nil }
        let half = ContractConstants.patchSize / 2
        let columns = max(0, point.x - half)..<min(outputPixelSize.width, point.x + half)
        let rows = max(0, point.y - half)..<min(outputPixelSize.height, point.y + half)
        let width = Double(outputPixelSize.width)
        let height = Double(outputPixelSize.height)
        let rect = GlobalRect(
            x: captureRect.x + Double(columns.lowerBound) * captureRect.width / width,
            y: captureRect.y + Double(rows.lowerBound) * captureRect.height / height,
            width: Double(columns.count) * captureRect.width / width,
            height: Double(rows.count) * captureRect.height / height)
        return TargetPatch(
            center: point, columns: columns, rows: rows, globalRect: rect, frameSize: outputPixelSize)
    }
}

extension GlobalRect {
    fileprivate var isUsable: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

extension Double {
    /// Clamps into `[lower, upper)`: the far edge of a display belongs to its neighbour.
    fileprivate func clamped(from lower: Double, below upper: Double) -> Double {
        Swift.max(lower, Swift.min(self, upper.nextDown))
    }
}
