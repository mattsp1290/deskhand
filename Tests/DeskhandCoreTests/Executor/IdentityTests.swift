import DeskhandCore
import Testing

/// The app policy before admission, at the last look and before every event (contract 6.7, 6.9,
/// 12.3, 12.4), and the identities bound at the last look (bean bhwb).
@Suite("Executor: app identity", .timeLimit(.minutes(1)))
struct IdentityTests {
    static let textEditWindow = ObservedWindow(owner: ExecutorFixture.textEdit, title: "notes.txt")

    func measured(_ answer: EffectAnswer) -> JSONValue? { answer.structuredContent?["measured"] }

    @Test("a switch of the frontmost app between two allowed apps aborts typing with denied_app")
    func frontmostSwitchWhileTyping() async throws {
        let mac = FakeMac { $0.afterPost[2] = { world, _ in world.frontmost = ExecutorFixture.notes } }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "hello"]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 2))
        #expect(answer.details == ["denied_by": "policy"])
        #expect(measured(answer)?["target_app"]?["bundle_id"] == "com.apple.Notes")
        #expect(measured(answer)?["frontmost_app"]?["bundle_id"] == "com.apple.Notes")
        #expect(measured(answer)?["window_title"] == .null)
        #expect(mac.posted.count == 2)
        #expect(mac.released == [.key(ExecutorFixture.carrier)])
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(try await harness.status() == .found(OperationView(status: .aborted, eventsPosted: 2)))
    }

    @Test("a switch of the frontmost app between two allowed apps aborts a click before the press")
    func frontmostSwitchBeforeClick() async throws {
        let mac = FakeMac { $0.afterPost[1] = { world, _ in world.frontmost = ExecutorFixture.notes } }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 20, "y": 30]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 1))
        #expect(answer.details == ["denied_by": "policy"])
        #expect(measured(answer)?["global_point"] == ["x": 20.5, "y": 30.5])
        #expect(mac.posted == [.pointerMove(to: GlobalPoint(x: 20.5, y: 30.5), dragging: nil)])
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("typing aborts when another allowed app comes to the front and takes keyboard focus with it")
    func appSwitchWhileTyping() async throws {
        let mac = FakeMac {
            $0.afterPost[2] = { world, _ in
                world.frontmost = ExecutorFixture.notes
                world.focus = ObservedWindow(owner: ExecutorFixture.notes, title: "list")
            }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "hello"]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 2))
        #expect(answer.details == ["denied_by": "policy"])
        #expect(measured(answer)?["frontmost_app"]?["bundle_id"] == "com.apple.Notes")
        #expect(mac.posted.count == 2)
        #expect(mac.released == [.key(ExecutorFixture.carrier)])
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("a click on a background window of an allowed app completes when that app comes to the front")
    func clickActivatesBackgroundWindow() async throws {
        let mac = FakeMac {
            $0.frontmost = ExecutorFixture.notes
            $0.afterPost[2] = { world, _ in world.frontmost = ExecutorFixture.textEdit }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 20, "y": 30]))

        let result = try #require(answer.result)
        #expect(result.eventsPosted == 3)
        #expect(result.measured.frontmostApp.bundleID == "com.apple.Notes")
        #expect(result.measured.targetApp?.bundleID == "com.apple.TextEdit")
        #expect(mac.posted.count == 3)
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(try await harness.status() == .found(OperationView(status: .completed, eventsPosted: 3)))
    }

    @Test("a click aborts when the front switches to an allowed app that does not own the clicked window")
    func clickActivatesAnotherApp() async throws {
        let preview = ExecutorFixture.app("com.apple.Preview", "Preview")
        let mac = FakeMac {
            $0.policy.allowed.insert(AllowedApp(bundleID: BundleID("com.apple.Preview")!, signer: .apple))
            $0.frontmost = ExecutorFixture.notes
            $0.afterPost[2] = { world, _ in world.frontmost = preview }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 20, "y": 30]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 2))
        #expect(answer.details == ["denied_by": "policy"])
        #expect(measured(answer)?["frontmost_app"]?["bundle_id"] == "com.apple.Preview")
        #expect(mac.released == [.button(.left)])
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("a switch to the clicked window's app before the button goes down aborts the click")
    func switchToWindowOwnerBeforePress() async throws {
        let mac = FakeMac {
            $0.frontmost = ExecutorFixture.notes
            $0.afterPost[1] = { world, _ in world.frontmost = ExecutorFixture.textEdit }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 20, "y": 30]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 1))
        #expect(mac.posted == [.pointerMove(to: GlobalPoint(x: 20.5, y: 30.5), dragging: nil)])
    }

    @Test("a drag from a background window keeps going when its app comes to the front over another window")
    func dragActivatesBackgroundWindowLate() async throws {
        let notesWindow = ObservedWindow(owner: ExecutorFixture.notes, title: "list")
        // Activation lands only once the pointer is already over the Notes window.
        let activate: FakeMac.Change = { world, _ in
            guard case .posted(.pointerMove(let point, _))? = world.trace.last, point.x >= 100 else { return }
            world.frontmost = ExecutorFixture.textEdit
        }
        let mac = FakeMac {
            $0.frontmost = ExecutorFixture.notes
            $0.windows = { point in point.x >= 100 ? notesWindow : IdentityTests.textEditWindow }
            for index in 3...200 { $0.afterPost[index] = activate }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.pointer([
                "type": "drag", "path": [["x": 10, "y": 50], ["x": 200, "y": 50]], "duration_ms": 100,
            ]))

        let result = try #require(answer.result)
        #expect(mac.read(\.frontmost) == ExecutorFixture.textEdit)
        #expect(result.measured.frontmostApp.bundleID == "com.apple.Notes")
        #expect(result.measured.dragEnd?.targetApp.bundleID == "com.apple.Notes")
        #expect(result.eventsPosted == mac.posted.count)
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("after the front followed a click, a switch back to the app it left aborts")
    func switchBackAfterActivation() async throws {
        let mac = FakeMac {
            $0.frontmost = ExecutorFixture.notes
            $0.afterPost[2] = { world, _ in world.frontmost = ExecutorFixture.textEdit }
            $0.afterPost[3] = { world, _ in world.frontmost = ExecutorFixture.notes }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.pointer(["type": "click", "x": 20, "y": 30, "count": 2]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 3))
        #expect(measured(answer)?["frontmost_app"]?["bundle_id"] == "com.apple.Notes")
    }

    @Test("a change of keyboard focus to another allowed app aborts typing")
    func focusSwitch() async throws {
        let mac = FakeMac {
            $0.afterPost[4] = { world, _ in world.focus = ObservedWindow(owner: ExecutorFixture.notes, title: "list") }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.keyboard(["type": "type", "text": "abc"]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation?.eventsPosted == 4)
        #expect(measured(answer)?["target_app"]?["bundle_id"] == "com.apple.Notes")
        #expect(measured(answer)?["frontmost_app"]?["bundle_id"] == "com.apple.TextEdit")
    }

    @Test("a denied window under the target is refused before admission with point_index 0")
    func deniedWindowBeforeAdmission() async throws {
        let mac = FakeMac { $0.windows = { _ in ObservedWindow(owner: ExecutorFixture.terminal, title: "zsh") } }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 40, "y": 50]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation == nil)
        #expect(answer.details == ["denied_by": "policy", "point_index": 0])
        #expect(measured(answer)?["target_app"]?["bundle_id"] == "com.apple.Terminal")
        #expect(measured(answer)?["window_title"] == .null)
        #expect(measured(answer)?["global_point"] == ["x": 40.5, "y": 50.5])
        #expect(mac.posted.isEmpty)
        #expect(try await harness.status() == .notFound)
    }

    @Test("a denied window that appears under the target aborts before the button goes down")
    func deniedWindowDuringClick() async throws {
        let mac = FakeMac {
            $0.afterPost[2] = { world, _ in
                world.windows = { _ in ObservedWindow(owner: ExecutorFixture.unlisted, title: "panel") }
            }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.pointer(["type": "click", "x": 40, "y": 50, "modifiers": ["shift"]]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: 2))
        #expect(answer.details == ["denied_by": "policy", "point_index": 0])
        #expect(mac.posted.count == 2)
        #expect(mac.released == [.modifierKey(.shift)])
        #expect(mac.ledgerOnDisk.isEmpty)
    }

    @Test("an uncertain identity refuses, even when what was read looks allowed")
    func uncertainIdentity() async throws {
        let unsure = ExecutorFixture.app("com.apple.TextEdit", "TextEdit", certain: false)
        let frontmost = try Harness(mac: FakeMac { $0.frontmost = unsure })
        let byFrontmost = await frontmost.executor.perform(try frontmost.pointer(["type": "move", "x": 3, "y": 4]))
        let focus = try Harness(mac: FakeMac { $0.focus = ObservedWindow(owner: unsure, title: "notes.txt") })
        let byFocus = await focus.executor.perform(try focus.keyboard(["type": "type", "text": "x"]))

        for (answer, harness) in [(byFrontmost, frontmost), (byFocus, focus)] {
            #expect(answer.code == .deniedApp)
            #expect(answer.details == ["denied_by": "policy"])
            #expect(measured(answer)?["target_app"]?["bundle_id"] == "com.apple.TextEdit")
            #expect(harness.mac.posted.isEmpty)
        }
    }

    @Test("a window owner that becomes uncertain during the operation aborts it")
    func uncertainWindowDuringScroll() async throws {
        let mac = FakeMac {
            $0.afterPost[1] = { world, _ in world.windows = { _ in ObservedWindow(owner: .undetermined, title: nil) } }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(try harness.pointer(["type": "scroll", "x": 5, "y": 5, "dy": 50]))

        #expect(answer.code == .deniedApp)
        #expect(answer.operation?.eventsPosted == 1)
        #expect(measured(answer)?["target_app"] == ["bundle_id": .null, "team_id": .null, "name": ""])
    }

    @Test("permitted_apps narrows the policy: denied_by permitted_apps")
    func permittedApps() async throws {
        let harness = try Harness()
        let answer = await harness.executor.perform(
            try harness.pointer(["type": "move", "x": 1, "y": 1], permitted: ["com.apple.Notes"]))
        #expect(answer.code == .deniedApp)
        #expect(answer.details == ["denied_by": "permitted_apps"])
        #expect(measured(answer)?["target_app"]?["bundle_id"] == "com.apple.TextEdit")
    }

    @Test("a drag stops before it moves onto a denied window and drops where the pointer is")
    func dragAcrossDeniedWindow() async throws {
        let mac = FakeMac {
            $0.afterPost[2] = { world, _ in
                world.windows = { point in
                    point.x >= 100
                        ? ObservedWindow(owner: ExecutorFixture.terminal, title: "zsh") : IdentityTests.textEditWindow
                }
            }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.pointer([
                "type": "drag", "path": [["x": 10, "y": 50], ["x": 200, "y": 50]], "duration_ms": 100,
            ]))

        #expect(answer.code == .deniedApp)
        #expect(answer.details == ["denied_by": "policy", "point_index": 1])
        let moves = mac.posted.compactMap { event -> GlobalPoint? in
            guard case .pointerMove(let point, _) = event else { return nil }
            return point
        }
        #expect(moves.allSatisfy { $0.x < 100 })
        #expect(moves.count > 2)
        let checked = try #require(measured(answer)?["global_point"]?["x"])
        #expect(checked.intValue == nil && checked != .null)
        if case .number(let x) = checked { #expect(x >= 100) }
        #expect(mac.released == [.button(.left)])
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: mac.posted.count))
        #expect(measured(answer)?["drag_end"] == nil)
    }

    @Test("a drag whose path crosses a denied window is refused before admission")
    func dragPathRefused() async throws {
        let mac = FakeMac {
            $0.windows = { point in
                (60..<70).contains(point.x)
                    ? ObservedWindow(owner: ExecutorFixture.terminal, title: "zsh") : IdentityTests.textEditWindow
            }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.pointer([
                "type": "drag", "path": [["x": 10, "y": 50], ["x": 50, "y": 50], ["x": 100, "y": 50]],
            ]))
        #expect(answer.code == .deniedApp)
        #expect(answer.details == ["denied_by": "policy", "point_index": 2])
        #expect(mac.posted.isEmpty)
    }

    @Test("an abort reports no title of a capture-excluded app, in the answer or the record")
    func abortedMeasuredHidesTitle() async throws {
        var policy = ExecutorFixture.policy
        policy.captureExclusions.insert(BundleIDFamily(BundleID("com.apple.Notes")!))
        let mac = FakeMac {
            $0.policy = policy
            $0.focus = ObservedWindow(owner: ExecutorFixture.notes, title: "secret")
            $0.afterPost[1] = { world, _ in world.idleMs = 0 }
        }
        let harness = try Harness(mac: mac)
        let call = try harness.keyboard(["type": "type", "text": "hi"])
        let answer = await harness.executor.perform(call)

        #expect(answer.code == .userActive)
        #expect(measured(answer)?["target_app"]?["bundle_id"] == "com.apple.Notes")
        #expect(measured(answer)?["window_title"] == .null)
        mac.change { $0.idleMs = 60_000 }
        let replay = await harness.executor.perform(call)
        guard case .replayed(_, let stored) = replay else {
            Issue.record("expected a replay, got \(replay)")
            return
        }
        #expect(stored["measured"]?["window_title"] == .null)
    }

    @Test("an abort for another cause reports no title of a window the policy refuses")
    func abortHidesDeniedWindowTitle() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        // Between step 14 and the last look a denied app's window comes under the target and the
        // person touches the mouse; user_active outranks denied_app.
        await harness.onLog(.intent) {
            mac.change {
                $0.windows = { _ in ObservedWindow(owner: ExecutorFixture.unlisted, title: "Inbox - someone") }
                $0.idleMs = 5
            }
        }
        let answer = await harness.executor.perform(try harness.pointer(["type": "click", "x": 20, "y": 20]))
        #expect(answer.code == .userActive)
        #expect(measured(answer)?["target_app"]?["bundle_id"] == "com.example.Unlisted")
        #expect(measured(answer)?["window_title"] == .null)
    }

    @Test("success reports the last look's facts, titles of capture-excluded apps removed")
    func successMeasured() async throws {
        var policy = ExecutorFixture.policy
        policy.captureExclusions.insert(BundleIDFamily(BundleID("com.apple.Notes")!))
        let mac = FakeMac {
            $0.policy = policy
            $0.windows = { point in
                point.x > 100
                    ? ObservedWindow(owner: ExecutorFixture.notes, title: "secret") : IdentityTests.textEditWindow
            }
        }
        let harness = try Harness(mac: mac)
        let answer = await harness.executor.perform(
            try harness.pointer([
                "type": "drag", "path": [["x": 10, "y": 10], ["x": 150, "y": 10]], "duration_ms": 50,
            ]))
        let result = try #require(answer.result)
        #expect(result.measured.targetApp?.bundleID == "com.apple.TextEdit")
        #expect(result.measured.windowTitle == "notes.txt")
        #expect(result.measured.globalPoint == GlobalPoint(x: 10.5, y: 10.5))
        #expect(result.measured.dragEnd?.targetApp.bundleID == "com.apple.Notes")
        #expect(result.measured.dragEnd?.windowTitle == nil)
        #expect(result.measured.dragEnd?.globalPoint == GlobalPoint(x: 150.5, y: 10.5))
    }
}
