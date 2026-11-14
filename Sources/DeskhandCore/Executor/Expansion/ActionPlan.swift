/// A point of a `pointer` action whose window owner is checked, in both coordinate spaces.
public struct PointerTarget: Hashable, Sendable {
    /// `details.point_index` of a refusal here: 0 for `move`, `click` and `scroll`; for a `drag`
    /// the point of `path` that ends the segment being checked (contract 6.9).
    public let pointIndex: Int
    public let framePoint: FramePoint
    public let globalPoint: GlobalPoint

    public init(pointIndex: Int, framePoint: FramePoint, globalPoint: GlobalPoint) {
        self.pointIndex = pointIndex
        self.framePoint = framePoint
        self.globalPoint = globalPoint
    }
}

/// The apps the checks before an event look at besides the frontmost app (contract 6.9).
public enum CheckTarget: Hashable, Sendable {
    /// `keyboard`: the owner of keyboard focus.
    case keyboardFocus
    /// `pointer`: the owner of the topmost window under the point the event acts at, or moves to.
    case point(PointerTarget)
}

/// One event of a plan with what the executor does around it (contract 12.3 step 6): the ledger
/// entry of ``InputEvent/press`` is written before the checks, and ``clears`` is cleared once the
/// event was posted.
public struct PlannedEvent: Hashable, Sendable {
    public let event: InputEvent
    public let target: CheckTarget
    /// ``InputEvent/release`` for every up event but the carrier ups of `type` before its last: the
    /// carrier's entry is written once per `type` and cleared after the last up, so one ledger write
    /// guards the whole text. An entry left for an input that is up does no harm (contract 12.7).
    public let clears: HeldInput?
    /// The holds after this event are timed from when it was posted: the key of a `press`, the
    /// button of a `drag`.
    public let startsHold: Bool

    init(_ event: InputEvent, target: CheckTarget, clears: HeldInput? = nil, startsHold: Bool = false) {
        self.event = event
        self.target = target
        self.clears = clears
        self.startsHold = startsHold
    }
}

public enum PlanStep: Hashable, Sendable {
    case post(PlannedEvent)
    /// Waits with input held until `elapsed` has passed since the last event that
    /// ``PlannedEvent/startsHold``, checking `target` and everything else at every activity poll.
    case hold(until: Duration, target: CheckTarget)
}

/// An action expanded into the events the executor posts, in order (contract 6.4, 6.5, 6.6).
public struct ActionPlan: Hashable, Sendable {
    public let steps: [PlanStep]

    public var events: [PlannedEvent] {
        steps.compactMap { step in
            guard case .post(let planned) = step else { return nil }
            return planned
        }
    }
}

/// The points of a `pointer` action that its app-policy checks look at (contract 6.7, 6.9).
public struct PointerTargets: Hashable, Sendable {
    /// Every sample of ``PointerAction/policySamples``, checked before admission and moved through
    /// by a `drag`.
    public let samples: [PointerTarget]
    /// The frame's, which also converts scroll deltas to points.
    public let geometry: FrameGeometry

    /// `nil` when a point lies outside the frame: that call is refused with `out_of_frame` first.
    public init?(_ action: PointerAction, geometry: FrameGeometry) {
        var samples: [PointerTarget] = []
        for sample in action.policySamples {
            guard let global = geometry.globalPoint(for: sample.point) else { return nil }
            samples.append(PointerTarget(pointIndex: sample.pointIndex, framePoint: sample.point, globalPoint: global))
        }
        self.samples = samples
        self.geometry = geometry
    }

    /// Where the first target point mapped: `measured.global_point`.
    public var first: PointerTarget { samples[0] }

    /// The last point of a `drag`'s path: `measured.drag_end`.
    public var last: PointerTarget { samples[samples.count - 1] }
}
