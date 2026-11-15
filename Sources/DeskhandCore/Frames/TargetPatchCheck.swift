/// Recaptures and compares target patches (contract 8.4). The platform implements it: it captures at
/// least each patch's `globalRect` again, with the frame's app exclusions and no pointer, scales it
/// exactly as the frame was scaled, and compares with ``TargetPatch/compare(original:current:)``.
public protocol TargetPatchVerifier: Sendable {
    /// One verdict per patch, in the order given. Any failure to capture or compare is `unknown`.
    func verify(_ frame: LiveFrame, patches: [TargetPatch]) async -> [PatchVerdict]
}

extension PointerAction {
    /// The targets whose patches are checked, each with the index `details.point_index` reports: the
    /// one target of `move`, `click` and `scroll`; the first and last points of a `drag`.
    public var patchTargets: [(pointIndex: Int, point: FramePoint)] {
        switch self {
        case .drag(let drag): [(0, drag.path[0]), (drag.path.count - 1, drag.path[drag.path.count - 1])]
        case .move, .click, .scroll: [(0, points[0])]
        }
    }
}

public enum TargetPatchCheck {
    /// Refusal step 13: `pixels_changed` naming the first target whose patch did not verify as
    /// unchanged, or `nil` when every patch is unchanged. Fails closed: an `unknown` verdict, a target
    /// outside the frame, or a verifier answering with the wrong number of verdicts refuses the call.
    public static func run(
        _ action: PointerAction, on frame: LiveFrame, verifier: some TargetPatchVerifier
    ) async -> StaleFrameReason? {
        let targets = action.patchTargets
        var patches: [TargetPatch] = []
        for target in targets {
            guard let patch = frame.frame.geometry.targetPatch(around: target.point) else {
                return .pixelsChanged(pointIndex: target.pointIndex)
            }
            patches.append(patch)
        }
        let verdicts = await verifier.verify(frame, patches: patches)
        guard verdicts.count == targets.count else { return .pixelsChanged(pointIndex: targets[0].pointIndex) }
        guard let failed = zip(targets, verdicts).first(where: { $0.1 != .unchanged }) else { return nil }
        return .pixelsChanged(pointIndex: failed.0.pointIndex)
    }
}
