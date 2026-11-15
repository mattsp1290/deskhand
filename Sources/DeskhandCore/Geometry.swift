/// A point in global points (contract 8.1). May be negative and fractional.
public struct GlobalPoint: Hashable, Sendable, JSONRepresentable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var jsonValue: JSONValue { ["x": .number(x), "y": .number(y)] }
}

/// A rectangle in global points. The origin may be negative; width and height are at least 1.
public struct GlobalRect: Hashable, Sendable, JSONRepresentable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var jsonValue: JSONValue {
        ["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)]
    }
}

/// A size in whole pixels, each side at least 1.
public struct PixelSize: Hashable, Sendable, JSONRepresentable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var jsonValue: JSONValue { ["width": JSONValue(width), "height": JSONValue(height)] }
}

/// A pixel in the output pixel space of one frame: `(0, 0)` is the top-left pixel.
public struct FramePoint: Hashable, Sendable, JSONRepresentable {
    /// Coordinates outside this range are `invalid_argument`; inside it but off the frame, `out_of_frame`.
    public static let coordinateRange = -65_536...65_535

    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public var jsonValue: JSONValue { ["x": JSONValue(x), "y": JSONValue(y)] }
}
