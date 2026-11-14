public typealias PointerArguments = EffectArguments<PointerAction>

extension EffectArguments where Action == PointerAction {
    public init(arguments: JSONObject) throws(ArgumentError) {
        try self.init(arguments: arguments, action: PointerAction.decode)
    }
}

public struct Click: Hashable, Sendable {
    public let point: FramePoint
    public let button: MouseButton
    /// 1, 2 or 3, posted as one multi-click.
    public let count: Int
    public let modifiers: Set<Modifier>
}

/// A drag whose points are all equal is a press-and-hold for `durationMs`.
public struct Drag: Hashable, Sendable {
    /// 2 to 32 points.
    public let path: [FramePoint]
    public let button: MouseButton
    public let modifiers: Set<Modifier>
    /// The least time from button down to button up (contract 6.4). A long path takes longer,
    /// because every step is checked before the pointer moves there.
    public let durationMs: Int
}

/// Positive `dy` reveals content further down, positive `dx` further right. Not both zero.
public struct Scroll: Hashable, Sendable {
    public let point: FramePoint
    public let dx: Int
    public let dy: Int
    public let modifiers: Set<Modifier>
}

/// A `pointer` action (contract 6.4), defaults applied. Coordinates are frame pixels.
public enum PointerAction: Hashable, Sendable {
    case move(FramePoint)
    case click(Click)
    case drag(Drag)
    case scroll(Scroll)

    /// Every point the action targets, in order: the indexes `out_of_frame` reports.
    public var points: [FramePoint] {
        switch self {
        case .move(let point): [point]
        case .click(let click): [click.point]
        case .drag(let drag): drag.path
        case .scroll(let scroll): [scroll.point]
        }
    }

    static func decode(_ value: JSONValue, _ path: JSONPointer) throws(ArgumentError) -> PointerAction {
        guard case .string(let type) = value["type"] else { throw ArgumentError(at: path, "needs a string 'type'") }
        let coordinate = Decode.integer(FramePoint.coordinateRange)
        func point(_ reader: ObjectReader) throws(ArgumentError) -> FramePoint {
            FramePoint(x: try reader.required("x", coordinate), y: try reader.required("y", coordinate))
        }
        func modifiers(_ reader: ObjectReader) throws(ArgumentError) -> Set<Modifier> {
            try reader.optional("modifiers", Decode.modifiers) ?? []
        }
        func button(_ reader: ObjectReader) throws(ArgumentError) -> MouseButton {
            try reader.optional("button", Decode.oneOf(MouseButton.self)) ?? .left
        }
        switch type {
        case "move":
            return .move(try point(ObjectReader(value, at: path, allowing: ["type", "x", "y"])))
        case "click":
            let reader = try ObjectReader(
                value, at: path, allowing: ["type", "x", "y", "button", "count", "modifiers"])
            return .click(
                Click(
                    point: try point(reader), button: try button(reader),
                    count: try reader.optional("count", Decode.integer(1...3)) ?? 1, modifiers: try modifiers(reader)))
        case "drag":
            let reader = try ObjectReader(
                value, at: path, allowing: ["type", "path", "button", "modifiers", "duration_ms"])
            let pathPoints = try reader.required("path") { value, path throws(ArgumentError) in
                guard case .array(let items) = value, ContractConstants.dragPointCountRange.contains(items.count) else {
                    throw ArgumentError(at: path, "must be an array of 2 to 32 points")
                }
                var points: [FramePoint] = []
                for (index, item) in items.enumerated() {
                    points.append(try Decode.framePoint(item, path.appending(index)))
                }
                return points
            }
            let duration = Decode.integer(ContractConstants.dragDurationMsRange)
            let durationMs = try reader.optional("duration_ms", duration) ?? ContractConstants.defaultDragDurationMs
            return .drag(
                Drag(
                    path: pathPoints, button: try button(reader), modifiers: try modifiers(reader),
                    durationMs: durationMs))
        case "scroll":
            let reader = try ObjectReader(value, at: path, allowing: ["type", "x", "y", "dx", "dy", "modifiers"])
            let delta = Decode.integer(ContractConstants.scrollDeltaRange)
            let scroll = Scroll(
                point: try point(reader), dx: try reader.optional("dx", delta) ?? 0,
                dy: try reader.optional("dy", delta) ?? 0, modifiers: try modifiers(reader))
            guard scroll.dx != 0 || scroll.dy != 0 else { throw ArgumentError(at: path, "needs a non-zero dx or dy") }
            return .scroll(scroll)
        default:
            throw ArgumentError(at: path.appending("type"), "must be one of move, click, drag, scroll")
        }
    }
}
