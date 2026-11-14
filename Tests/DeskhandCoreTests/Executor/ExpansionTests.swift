import DeskhandCore
import Testing

@Suite("Action expansion")
struct ExpansionTests {
    let mac = FakeMac()
    let geometry = FrameGeometry(
        captureRect: GlobalRect(x: 0, y: 0, width: 400, height: 300),
        outputPixelSize: PixelSize(width: 400, height: 300),
        displayBounds: GlobalRect(x: 0, y: 0, width: 400, height: 300))!

    func keyboard(_ action: JSONValue) throws -> ActionPlan {
        let arguments: JSONObject = ["holder_id": "h", "frame_id": "f", "operation_id": "o", "action": action]
        return try ActionExpansion.keyboard(try KeyboardArguments(arguments: arguments).action, keyCodes: mac)
    }

    func pointer(_ action: JSONValue) throws -> ActionPlan {
        let arguments: JSONObject = ["holder_id": "h", "frame_id": "f", "operation_id": "o", "action": action]
        let parsed = try PointerArguments(arguments: arguments).action
        let targets = try #require(PointerTargets(parsed, geometry: geometry))
        return ActionExpansion.pointer(parsed, targets: targets, keyCodes: mac)
    }

    static let control = ExecutorFixture.modifierCodes[.control]!
    static let option = ExecutorFixture.modifierCodes[.option]!
    static let shift = ExecutorFixture.modifierCodes[.shift]!
    static let command = ExecutorFixture.modifierCodes[.command]!

    @Test("press: modifiers in press order, the key held for hold_ms, released in reverse")
    func pressOrder() throws {
        let plan = try keyboard([
            "type": "press", "key": "k", "modifiers": ["command", "control", "shift"], "hold_ms": 250,
        ])
        let k = ExecutorFixture.code(.k)
        #expect(
            plan.events.map(\.event) == [
                .modifierDown(Self.control), .modifierDown(Self.shift), .modifierDown(Self.command),
                .keyDown(k, text: nil), .keyUp(k, text: nil), .modifierUp(Self.command), .modifierUp(Self.shift),
                .modifierUp(Self.control),
            ])
        #expect(
            plan.events.map(\.clears) == [
                nil, nil, nil, nil, .key(k), .modifier(Self.command), .modifier(Self.shift), .modifier(Self.control),
            ])
        #expect(plan.events.map(\.startsHold) == [false, false, false, true, false, false, false, false])
        #expect(plan.steps[4] == .hold(until: .milliseconds(250), target: .keyboardFocus))
        #expect(plan.events.allSatisfy { $0.target == .keyboardFocus })
    }

    @Test("press with hold_ms 0 has no hold")
    func pressWithoutHold() throws {
        let plan = try keyboard(["type": "press", "key": "return"])
        #expect(plan.steps.count == 2)
        #expect(
            plan.events.map(\.event) == [
                .keyDown(ExecutorFixture.code(.return), text: nil), .keyUp(ExecutorFixture.code(.return), text: nil),
            ])
    }

    @Test("a key the active layout lacks is invalid_argument at /action/key")
    func missingKey() throws {
        mac.change { $0.missingKeys = [.grave] }
        #expect {
            try keyboard(["type": "press", "key": "`"])
        } throws: { error in
            (error as? ArgumentError)?.pointer == JSONPointer(["action", "key"])
        }
    }

    @Test("type: one carrier down and up per grapheme; only the last up clears the carrier")
    func typeCarrier() throws {
        let plan = try keyboard(["type": "type", "text": "he\u{301}y"])
        let carrier = ExecutorFixture.carrier
        #expect(
            plan.events.map(\.event) == [
                .keyDown(carrier, text: "h"), .keyUp(carrier, text: "h"), .keyDown(carrier, text: "e\u{301}"),
                .keyUp(carrier, text: "e\u{301}"), .keyDown(carrier, text: "y"), .keyUp(carrier, text: "y"),
            ])
        #expect(plan.events.map(\.clears) == [nil, nil, nil, nil, nil, .key(carrier)])
        #expect(plan.events.allSatisfy { !$0.startsHold })
    }

    @Test("a grapheme longer than one event carries is split between its scalars")
    func longGrapheme() {
        let cluster = "e" + String(repeating: "\u{301}", count: 30)
        let chunks = ActionExpansion.typedChunks(cluster)
        #expect(chunks.joined() == cluster)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.utf16.count <= ActionExpansion.maxTypedUnitsPerEvent })
        #expect(ActionExpansion.typedChunks("👩‍👩‍👧") == ["👩‍👩‍👧"])
    }

    @Test("click: move, modifiers, count presses as one multi-click, modifiers released in reverse")
    func click() throws {
        let plan = try pointer(["type": "click", "x": 10, "y": 20, "count": 3, "modifiers": ["command", "shift"]])
        let at = GlobalPoint(x: 10.5, y: 20.5)
        #expect(
            plan.events.map(\.event) == [
                .pointerMove(to: at, dragging: nil), .modifierDown(Self.shift), .modifierDown(Self.command),
                .buttonDown(.left, at: at, clickCount: 1), .buttonUp(.left, at: at, clickCount: 1),
                .buttonDown(.left, at: at, clickCount: 2), .buttonUp(.left, at: at, clickCount: 2),
                .buttonDown(.left, at: at, clickCount: 3), .buttonUp(.left, at: at, clickCount: 3),
                .modifierUp(Self.command), .modifierUp(Self.shift),
            ])
        let target = PointerTarget(pointIndex: 0, framePoint: FramePoint(x: 10, y: 20), globalPoint: at)
        #expect(plan.events.allSatisfy { $0.target == .point(target) })
    }

    @Test("move is one event")
    func move() throws {
        let plan = try pointer(["type": "move", "x": 0, "y": 299])
        #expect(plan.events.map(\.event) == [.pointerMove(to: GlobalPoint(x: 0.5, y: 299.5), dragging: nil)])
    }

    @Test("scroll is split into equal parts of at most 120 points, direction kept")
    func scroll() throws {
        let plan = try pointer(["type": "scroll", "x": 5, "y": 5, "dx": -30, "dy": 300])
        let scrolls = plan.events.compactMap { planned -> (Double, Double)? in
            guard case .scroll(let dx, let dy, _) = planned.event else { return nil }
            return (dx, dy)
        }
        #expect(scrolls.count == 3)
        #expect(scrolls.allSatisfy { $0.0 == -10 && $0.1 == 100 })
        #expect(plan.events.count == 4)
    }

    @Test("drag: moves at most 8 frame pixels apart, paced over duration_ms, released at the last point")
    func drag() throws {
        let plan = try pointer([
            "type": "drag", "path": [["x": 10, "y": 10], ["x": 50, "y": 13], ["x": 50, "y": 60]], "duration_ms": 800,
        ])
        let events = plan.events
        #expect(events.first?.event == .pointerMove(to: GlobalPoint(x: 10.5, y: 10.5), dragging: nil))
        #expect(events[1].event == .buttonDown(.left, at: GlobalPoint(x: 10.5, y: 10.5), clickCount: 1))
        #expect(events[1].startsHold)
        #expect(events.last?.event == .buttonUp(.left, at: GlobalPoint(x: 50.5, y: 60.5), clickCount: 1))
        #expect(
            events.last?.target
                == .point(
                    PointerTarget(
                        pointIndex: 2, framePoint: FramePoint(x: 50, y: 60), globalPoint: GlobalPoint(x: 50.5, y: 60.5))
                ))

        var previous = FramePoint(x: 10, y: 10)
        var indexes: [Int] = []
        for planned in events.dropFirst(2).dropLast() {
            guard case .pointerMove(_, let dragging) = planned.event, case .point(let target) = planned.target else {
                Issue.record("expected a drag move, got \(planned.event)")
                continue
            }
            #expect(dragging == .left)
            let dx = Double(target.framePoint.x - previous.x)
            let dy = Double(target.framePoint.y - previous.y)
            #expect((dx * dx + dy * dy).squareRoot() <= 8)
            previous = target.framePoint
            indexes.append(target.pointIndex)
        }
        #expect(previous == FramePoint(x: 50, y: 60))
        #expect(indexes == indexes.sorted())
        #expect(Set(indexes) == [1, 2])

        let holds = plan.steps.compactMap { step -> Duration? in
            guard case .hold(let until, _) = step else { return nil }
            return until
        }
        #expect(holds == holds.sorted())
        #expect(holds.last == .milliseconds(800))
        #expect(holds.dropLast().allSatisfy { $0 < .milliseconds(800) })
    }

    @Test("a drag whose points are equal holds the button at that point for duration_ms")
    func pressAndHold() throws {
        let plan = try pointer([
            "type": "drag", "path": [["x": 7, "y": 7], ["x": 7, "y": 7]], "duration_ms": 300, "modifiers": ["option"],
        ])
        let at = GlobalPoint(x: 7.5, y: 7.5)
        #expect(
            plan.events.map(\.event) == [
                .pointerMove(to: at, dragging: nil), .modifierDown(Self.option),
                .buttonDown(.left, at: at, clickCount: 1),
                .buttonUp(.left, at: at, clickCount: 1), .modifierUp(Self.option),
            ])
        #expect(
            plan.steps.contains(
                .hold(
                    until: .milliseconds(300),
                    target: .point(PointerTarget(pointIndex: 0, framePoint: FramePoint(x: 7, y: 7), globalPoint: at)))))
    }
}
