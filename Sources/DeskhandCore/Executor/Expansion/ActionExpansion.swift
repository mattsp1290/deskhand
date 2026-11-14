/// Turns an action into the events of contract 6.4 to 6.6. Pure: the same action, frame and layout
/// always give the same plan.
public enum ActionExpansion {
    /// The most UTF-16 code units one `type` event carries; macOS takes at most 20 per key event.
    public static let maxTypedUnitsPerEvent = 20
    /// The longest scroll one event posts, in global points. A longer scroll is split, so the checks
    /// run between its parts; the contract leaves the number of events open (contract 12.2).
    public static let maxScrollPointsPerEvent = 120.0

    /// A `keyboard` plan. A key the active layout lacks is `invalid_argument` (contract 6.5).
    public static func keyboard(_ action: KeyboardAction, keyCodes: some KeyCodeMapper) throws(ArgumentError)
        -> ActionPlan
    {
        switch action {
        case .type(let text):
            let carrier = keyCodes.textCarrier
            let chunks = typedChunks(text)
            var steps: [PlanStep] = []
            for (index, chunk) in chunks.enumerated() {
                steps.append(.post(PlannedEvent(.keyDown(carrier, text: chunk), target: .keyboardFocus)))
                let isLast = index == chunks.count - 1
                steps.append(
                    .post(
                        PlannedEvent(
                            .keyUp(carrier, text: chunk), target: .keyboardFocus, clears: isLast ? .key(carrier) : nil))
                )
            }
            return ActionPlan(steps: steps)
        case .press(let press):
            guard let code = keyCodes.code(for: press.key) else {
                throw ArgumentError(
                    at: JSONPointer.root.appending("action").appending("key"),
                    "the active keyboard layout has no key for '\(press.key.rawValue)'")
            }
            let modifiers = press.modifiers.sorted().map { keyCodes.code(for: $0) }
            var steps = modifiers.map { PlanStep.post(PlannedEvent(.modifierDown($0), target: .keyboardFocus)) }
            steps.append(.post(PlannedEvent(.keyDown(code, text: nil), target: .keyboardFocus, startsHold: true)))
            if press.holdMs > 0 { steps.append(.hold(until: .milliseconds(press.holdMs), target: .keyboardFocus)) }
            steps.append(.post(PlannedEvent(.keyUp(code, text: nil), target: .keyboardFocus, clears: .key(code))))
            steps += modifiers.reversed().map {
                .post(PlannedEvent(.modifierUp($0), target: .keyboardFocus, clears: .modifier($0)))
            }
            return ActionPlan(steps: steps)
        }
    }

    /// A `pointer` plan over the frame's targets. Modifiers wrap the presses in press order and are
    /// released in reverse (contract 6.6).
    public static func pointer(
        _ action: PointerAction, targets: PointerTargets, keyCodes: some KeyCodeMapper
    ) -> ActionPlan {
        let first = targets.first
        let move = PlanStep.post(
            PlannedEvent(.pointerMove(to: first.globalPoint, dragging: nil), target: .point(first)))
        func wrapped(
            _ modifiers: Set<Modifier>, from start: PointerTarget, to end: PointerTarget, _ inner: [PlanStep]
        ) -> [PlanStep] {
            let codes = modifiers.sorted().map { keyCodes.code(for: $0) }
            return codes.map { .post(PlannedEvent(.modifierDown($0), target: .point(start))) } + inner
                + codes.reversed().map {
                    .post(PlannedEvent(.modifierUp($0), target: .point(end), clears: .modifier($0)))
                }
        }
        switch action {
        case .move:
            return ActionPlan(steps: [move])
        case .click(let click):
            let presses = (1...click.count).flatMap { count -> [PlanStep] in
                [
                    .post(
                        PlannedEvent(
                            .buttonDown(click.button, at: first.globalPoint, clickCount: count), target: .point(first))),
                    .post(
                        PlannedEvent(
                            .buttonUp(click.button, at: first.globalPoint, clickCount: count), target: .point(first),
                            clears: .button(click.button))),
                ]
            }
            return ActionPlan(steps: [move] + wrapped(click.modifiers, from: first, to: first, presses))
        case .scroll(let scroll):
            let scrolls = scrollParts(dx: scroll.dx, dy: scroll.dy, targets: targets).map {
                PlanStep.post(PlannedEvent(.scroll(dx: $0.dx, dy: $0.dy, at: first.globalPoint), target: .point(first)))
            }
            return ActionPlan(steps: [move] + wrapped(scroll.modifiers, from: first, to: first, scrolls))
        case .drag(let drag):
            return ActionPlan(
                steps: [move] + wrapped(drag.modifiers, from: first, to: targets.last, dragSteps(drag, targets)))
        }
    }

    /// Button down at the first point, a move through every later sample at most
    /// `DRAG_POLICY_SAMPLE_PX` apart, spread over `duration_ms`, and the button up at the last point
    /// no sooner than `duration_ms` after it went down (contract 6.4, 6.9).
    private static func dragSteps(_ drag: Drag, _ targets: PointerTargets) -> [PlanStep] {
        var moves: [PointerTarget] = []
        var at = targets.first
        for sample in targets.samples.dropFirst() where sample.framePoint != at.framePoint {
            moves.append(sample)
            at = sample
        }
        let duration = Duration.milliseconds(drag.durationMs)
        var steps: [PlanStep] = [
            .post(
                PlannedEvent(
                    .buttonDown(drag.button, at: targets.first.globalPoint, clickCount: 1),
                    target: .point(targets.first),
                    startsHold: true))
        ]
        var previous = targets.first
        for (index, target) in moves.enumerated() {
            steps.append(.hold(until: duration * (index + 1) / (moves.count + 1), target: .point(previous)))
            steps.append(
                .post(PlannedEvent(.pointerMove(to: target.globalPoint, dragging: drag.button), target: .point(target)))
            )
            previous = target
        }
        steps.append(.hold(until: duration, target: .point(previous)))
        steps.append(
            .post(
                PlannedEvent(
                    .buttonUp(drag.button, at: targets.last.globalPoint, clickCount: 1), target: .point(targets.last),
                    clears: .button(drag.button))))
        return steps
    }

    /// The scroll in points, split into equal parts of at most ``maxScrollPointsPerEvent`` on each
    /// axis.
    static func scrollParts(dx: Int, dy: Int, targets: PointerTargets) -> [(dx: Double, dy: Double)] {
        let delta = targets.geometry.globalDelta(dx: dx, dy: dy)
        let parts = max(1, Int((max(abs(delta.dx), abs(delta.dy)) / maxScrollPointsPerEvent).rounded(.up)))
        return Array(repeating: (delta.dx / Double(parts), delta.dy / Double(parts)), count: parts)
    }

    /// The text of `type`, one grapheme cluster per event, a cluster longer than
    /// ``maxTypedUnitsPerEvent`` split between its scalars.
    public static func typedChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        for character in text {
            var chunk = String.UnicodeScalarView()
            var units = 0
            for scalar in character.unicodeScalars {
                let width = UTF16.width(scalar)
                if units + width > maxTypedUnitsPerEvent, !chunk.isEmpty {
                    chunks.append(String(chunk))
                    chunk = String.UnicodeScalarView()
                    units = 0
                }
                chunk.append(scalar)
                units += width
            }
            chunks.append(String(chunk))
        }
        return chunks
    }
}
