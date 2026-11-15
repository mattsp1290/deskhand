import Foundation

/// One active display (contract 6.2). In a mirror set only the primary is listed.
public struct DisplayInfo: Hashable, Sendable, JSONRepresentable {
    public var displayID: DisplayID
    /// Stable across reconfigurations, unlike `displayID`.
    public var uuid: UUID
    public var name: String
    public var isMain: Bool
    public var isBuiltin: Bool
    public var asleep: Bool
    /// Global points.
    public var bounds: GlobalRect
    /// Native pixels.
    public var pixelSize: PixelSize
    /// Native pixels per point.
    public var pointPixelScale: Double

    public init(
        displayID: DisplayID, uuid: UUID, name: String, isMain: Bool, isBuiltin: Bool, asleep: Bool,
        bounds: GlobalRect, pixelSize: PixelSize, pointPixelScale: Double
    ) {
        self.displayID = displayID
        self.uuid = uuid
        self.name = name
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.asleep = asleep
        self.bounds = bounds
        self.pixelSize = pixelSize
        self.pointPixelScale = pointPixelScale
    }

    public var jsonValue: JSONValue {
        [
            "display_id": JSONValue(displayID.rawValue), "uuid": .string(uuid.uuidString), "name": .string(name),
            "is_main": .bool(isMain), "is_builtin": .bool(isBuiltin), "asleep": .bool(asleep),
            "bounds": bounds.jsonValue, "pixel_size": pixelSize.jsonValue,
            "point_pixel_scale": .number(pointPixelScale),
        ]
    }
}

/// `structuredContent` of a successful `displays` call.
public struct DisplaysResult: Hashable, Sendable, JSONRepresentable {
    public var displayConfigGeneration: DisplayConfigGeneration
    public var displays: [DisplayInfo]

    public init(displayConfigGeneration: DisplayConfigGeneration, displays: [DisplayInfo]) {
        self.displayConfigGeneration = displayConfigGeneration
        self.displays = displays
    }

    public var jsonValue: JSONValue {
        [
            "display_config_generation": JSONValue(displayConfigGeneration.rawValue),
            "displays": .array(displays.map(\.jsonValue)),
        ]
    }
}
