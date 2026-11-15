public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg, png

    public var mimeType: String { "image/\(rawValue)" }
}

/// A JPEG quality step, in the order deskhand tries them (contract 7).
public enum JPEGQuality: Int, CaseIterable, Sendable {
    case q85 = 85
    case q75 = 75
    case q65 = 65
    case q60 = 60
}

/// How the returned image was encoded. Only JPEG has a quality.
public enum ImageEncoding: Hashable, Sendable {
    case jpeg(JPEGQuality)
    case png

    public var format: ImageFormat {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        }
    }
}

/// `screenshot` arguments (contract 6.3), defaults applied.
public struct ScreenshotArguments: Hashable, Sendable {
    public let holderID: HolderID
    /// `nil` means the main display. Whether it is active is checked against the live configuration.
    public let displayID: DisplayID?
    /// `nil` means the whole display. Whether it lies inside the display is checked against its bounds.
    public let region: GlobalRect?
    public let format: ImageFormat
    public let maxLongEdge: Int

    public init(arguments: JSONObject) throws(ArgumentError) {
        let names: Set = ["holder_id", "display_id", "region", "format", "max_long_edge"]
        let reader = try ObjectReader(.object(arguments), at: .root, allowing: names)
        holderID = try reader.required("holder_id", Decode.identifier(HolderID.self))
        displayID = try reader.optional("display_id", Decode.integer(0...Int(UInt32.max))).map { DisplayID(UInt32($0)) }
        region = try reader.optional("region") { value, path throws(ArgumentError) in
            let rect = try ObjectReader(value, at: path, allowing: ["x", "y", "width", "height"])
            return GlobalRect(
                x: try rect.required("x", Decode.number()), y: try rect.required("y", Decode.number()),
                width: try rect.required("width", Decode.number(minimum: 1)),
                height: try rect.required("height", Decode.number(minimum: 1))
            )
        }
        format = try reader.optional("format", Decode.oneOf(ImageFormat.self)) ?? .jpeg
        let edges = ContractConstants.minLongEdge...ContractConstants.maxLongEdge
        maxLongEdge = try reader.optional("max_long_edge", Decode.integer(edges)) ?? ContractConstants.maxLongEdge
    }
}

/// `structuredContent` of a successful `screenshot` call: the frame's metadata (contract 6.3).
public struct ScreenshotResult: Hashable, Sendable, JSONRepresentable {
    public var frameID: FrameID
    /// Of the encoded image bytes, before base64.
    public var sha256: SHA256Hex
    public var displayID: DisplayID
    public var displayConfigGeneration: DisplayConfigGeneration
    public var captureRect: GlobalRect
    public var sourcePixelSize: PixelSize
    /// The frame pixel space that pointer targets use.
    public var outputPixelSize: PixelSize
    public var pointPixelScale: Double
    /// In (0, 1].
    public var downscale: Double
    public var encoding: ImageEncoding
    public var imageBytes: Int
    public var capturedAt: Timestamp
    public var maxAgeMs: Int
    /// `nil` when the pointer was outside `captureRect`.
    public var pointerPosition: FramePoint?
    public var frontmostApp: AppRef

    public init(
        frameID: FrameID, sha256: SHA256Hex, displayID: DisplayID, displayConfigGeneration: DisplayConfigGeneration,
        captureRect: GlobalRect, sourcePixelSize: PixelSize, outputPixelSize: PixelSize, pointPixelScale: Double,
        downscale: Double, encoding: ImageEncoding, imageBytes: Int, capturedAt: Timestamp, maxAgeMs: Int,
        pointerPosition: FramePoint?, frontmostApp: AppRef
    ) {
        self.frameID = frameID
        self.sha256 = sha256
        self.displayID = displayID
        self.displayConfigGeneration = displayConfigGeneration
        self.captureRect = captureRect
        self.sourcePixelSize = sourcePixelSize
        self.outputPixelSize = outputPixelSize
        self.pointPixelScale = pointPixelScale
        self.downscale = downscale
        self.encoding = encoding
        self.imageBytes = imageBytes
        self.capturedAt = capturedAt
        self.maxAgeMs = maxAgeMs
        self.pointerPosition = pointerPosition
        self.frontmostApp = frontmostApp
    }

    public var jsonValue: JSONValue {
        var object: JSONObject = [
            "frame_id": .string(frameID.rawValue), "sha256": .string(sha256.description),
            "display_id": JSONValue(displayID.rawValue),
            "display_config_generation": JSONValue(displayConfigGeneration.rawValue),
            "capture_rect": captureRect.jsonValue, "source_pixel_size": sourcePixelSize.jsonValue,
            "output_pixel_size": outputPixelSize.jsonValue, "point_pixel_scale": .number(pointPixelScale),
            "downscale": .number(downscale), "format": .string(encoding.format.rawValue),
            "mime_type": .string(encoding.format.mimeType), "image_bytes": JSONValue(imageBytes),
            "captured_at": capturedAt.jsonValue, "max_age_ms": JSONValue(maxAgeMs),
            "pointer_position": pointerPosition?.jsonValue ?? .null, "frontmost_app": frontmostApp.jsonValue,
        ]
        if case .jpeg(let quality) = encoding { object["jpeg_quality"] = JSONValue(quality.rawValue) }
        return .object(object)
    }
}
