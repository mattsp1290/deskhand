import DeskhandCore
import Testing

/// An abort's releases through the executor (contract 10.3 step 2, 11.2, 12.4, 12.8): released at
/// once when cleanup is authorized, otherwise deferred with `cleanup_pending` until a retry posts
/// them.
@Suite("Release: aborts and deferred releases")
struct AbortReleaseTests {
    @Test(
        "an abort mid-chord releases the chord newest first when cleanup is authorized",
        arguments: [
            [BlockingState.displayAsleep], [.paused], [.gated], [.disarmed], [.permissionMissing], [.permissionStale],
        ] as [Set<BlockingState>])
    func abortReleasesInReverse(states: Set<BlockingState>) async throws {
        let harness = try ReleaseHarness(mac: HeldChord.mac(abortingWith: states))
        let answer = await harness.executor.perform(try harness.keyboard(HeldChord.action))
        #expect(answer.toolError?.state == ActiveStates(states).current)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: HeldChord.downEvents))
        #expect(harness.mac.released == HeldChord.released)
        #expect(harness.mac.heldDown.isEmpty)
        #expect(harness.mac.ledgerOnDisk.isEmpty)
        #expect(harness.mac.read(\.cleanupPending).last == false)
        #expect(await harness.executor.owesReleases == false)
        #expect(await harness.executor.nextCleanupRetry(at: harness.mac.reading) == nil)
    }

    @Test("an abort for a lock defers; cleanup_pending refuses effects until a retry after the unlock")
    func lockDefersUntilUnlock() async throws {
        let mac = HeldChord.mac(abortingWith: [.locked])
        let harness = try ReleaseHarness(mac: mac)
        let executor = harness.executor
        let answer = await executor.perform(try harness.keyboard(HeldChord.action))
        #expect(answer.code == .locked)
        #expect(answer.operation == OperationView(status: .aborted, eventsPosted: HeldChord.downEvents))
        #expect(mac.released.isEmpty)
        #expect(mac.heldDown == Set(HeldChord.pressed))
        #expect(mac.ledgerOnDisk == HeldChord.pressed)
        #expect(mac.read(\.cleanupPending).last == true)
        #expect(await executor.owesReleases)
        #expect(try await harness.move("op-2").code == .locked)

        // The abort was the first attempt: the next one is due a second later, while still locked.
        let abortedAt = mac.reading
        #expect(await executor.nextCleanupRetry(at: abortedAt) == abortedAt.instant(afterMilliseconds: 1000))
        #expect(await executor.retryCleanup(now: abortedAt) == nil)
        mac.advance(byMilliseconds: 1000)
        guard case .attempted(.deferred([.locked]))? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("a due retry while locked did not defer")
            return
        }
        #expect(mac.released.isEmpty)

        mac.advance(byMilliseconds: 200)
        mac.setState([])
        #expect(try await harness.move("op-3").code == .cleanupPending)
        #expect(await executor.nextCleanupRetry(at: mac.reading) == mac.reading.monotonic)
        guard case .attempted(.complete)? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("the unlock did not release at once")
            return
        }
        #expect(mac.released == HeldChord.released)
        #expect(mac.heldDown.isEmpty)
        #expect(mac.ledgerOnDisk.isEmpty)
        #expect(mac.read(\.cleanupPending).last == false)
        #expect(await executor.nextCleanupRetry(at: mac.reading) == nil)
        #expect(try await harness.move("op-4").result != nil)
    }

    static let deferring: [(Set<BlockingState>, Set<Condition>, Set<CleanupBlocker>, ToolErrorCode)] = [
        ([.secureInput], [], [.secureInput], .secureInput),
        ([.notConsole], [], [.notConsole], .notConsole),
        ([.notConsole], [.loginWindow], [.notConsole, .loginWindow], .notConsole),
        ([.paused, .disarmed, .locked], [], [.locked], .paused),
        ([.gated, .disarmed, .secureInput], [], [.secureInput], .gated),
    ]

    @Test(
        "secure input, a console switch or the login window defer the releases, whatever state outranks them",
        arguments: deferring)
    func otherBlockersDefer(
        states: Set<BlockingState>, conditions: Set<Condition>, blockers: Set<CleanupBlocker>, code: ToolErrorCode
    ) async throws {
        let mac = HeldChord.mac(abortingWith: states, conditions: conditions)
        let harness = try ReleaseHarness(mac: mac)
        let answer = await harness.executor.perform(try harness.keyboard(HeldChord.action))
        #expect(answer.code == code)
        #expect(mac.released.isEmpty)
        #expect(mac.ledgerOnDisk == HeldChord.pressed)
        #expect(await harness.executor.owesReleases)

        mac.advance(byMilliseconds: 1000)
        guard case .attempted(.deferred(let found))? = await harness.executor.retryCleanup(now: mac.reading) else {
            Issue.record("released while \(blockers) held")
            return
        }
        #expect(found == blockers)
        #expect(mac.released.isEmpty)

        mac.setState(states.subtracting([.locked, .notConsole, .secureInput]))
        guard case .attempted(.complete)? = await harness.executor.retryCleanup(now: mac.reading) else {
            Issue.record("not released once the blockers ended")
            return
        }
        #expect(mac.released == HeldChord.released)
        #expect(await harness.executor.owesReleases == false)
    }

    @Test(
        "deferred releases go out when the blockers end, even if gated, paused or disarmed then hold",
        arguments: [[BlockingState.paused], [.gated], [.disarmed]] as [Set<BlockingState>])
    func releaseWhileLeaseDroppingState(states: Set<BlockingState>) async throws {
        let mac = HeldChord.mac(abortingWith: [.locked])
        let harness = try ReleaseHarness(mac: mac)
        #expect(await harness.executor.perform(try harness.keyboard(HeldChord.action)).code == .locked)
        mac.setState(states)
        guard case .attempted(.complete)? = await harness.executor.retryCleanup(now: mac.reading) else {
            Issue.record("not released while \(states)")
            return
        }
        #expect(mac.released == HeldChord.released)
        #expect(mac.read(\.cleanupPending).last == false)
    }

    @Test("a release that cannot be posted stays owed, refuses effects and is tried again a second later")
    func failedReleaseRetried() async throws {
        let faults = ReleaseFaults()
        faults.arm { $0.failingReleases = [2, 3] }
        let mac = HeldChord.mac(abortingWith: [.displayAsleep])
        let harness = try ReleaseHarness(mac: mac, faults: faults)
        let executor = harness.executor
        #expect(await executor.perform(try harness.keyboard(HeldChord.action)).code == .displayAsleep)
        #expect(mac.released == [.named(.k)])
        #expect(mac.ledgerOnDisk == Array(HeldChord.pressed.prefix(3)))
        #expect(mac.read(\.cleanupPending).last == true)

        mac.setState([])
        #expect(try await harness.move("op-2").code == .cleanupPending)
        guard case .attempted(.postFailed(let input, _))? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("the change of state did not set off a retry")
            return
        }
        #expect(input == .modifierKey(.shift))
        #expect(await executor.retryCleanup(now: mac.reading) == nil)
        mac.advance(byMilliseconds: 999)
        #expect(await executor.retryCleanup(now: mac.reading) == nil)
        mac.advance(byMilliseconds: 1)
        guard case .attempted(.complete)? = await executor.retryCleanup(now: mac.reading) else {
            Issue.record("the retry a second later did not release")
            return
        }
        #expect(mac.released == HeldChord.released)
        #expect(mac.heldDown.isEmpty)
        #expect(mac.read(\.cleanupPending).last == false)
        #expect(try await harness.move("op-3").result != nil)
    }

    @Test("a release never moves the pointer: a drag's button goes up where the pointer stopped")
    func releaseDoesNotMovePointer() async throws {
        let drag: JSONValue = [
            "type": "drag", "path": [["x": 3, "y": 3], ["x": 200, "y": 3]], "duration_ms": 400,
        ]
        for state: BlockingState in [.displayAsleep, .locked] {
            let mac = FakeMac {
                $0.afterPost[3] = { world, now in world.report = ExecutorFixture.report([state], at: now) }
            }
            let harness = try ReleaseHarness(mac: mac)
            let answer = await harness.executor.perform(try harness.pointer(drag))
            let posted = try #require(answer.operation?.eventsPosted)
            mac.setState([])
            _ = await harness.executor.retryCleanup(now: mac.reading)
            #expect(mac.released == [.button(.left)], "\(state)")
            #expect(mac.posted.count == posted, "cleanup posted more than the release, \(state)")
            #expect(mac.heldDown.isEmpty, "\(state)")
        }
    }

    /// Tries to move the pointer before releasing, as no handler may.
    struct PointerMovingHandler: ReleaseHandler {
        func release(
            _ inputs: [HeldInput], from ledger: inout HeldInputLedger, poster: any EventPoster,
            authorization: () -> CleanupAuthorization
        ) -> CleanupOutcome {
            try? poster.post(.pointerMove(to: GlobalPoint(x: 0, y: 0), dragging: .left))
            return HeldInputReleaser().release(inputs, from: &ledger, poster: poster, authorization: authorization)
        }
    }

    @Test("the poster a release handler gets refuses everything but releases")
    func handlerCannotPost() async throws {
        let mac = HeldChord.mac(abortingWith: [.displayAsleep])
        let harness = try ReleaseHarness(mac: mac, releases: PointerMovingHandler())
        #expect(await harness.executor.perform(try harness.keyboard(HeldChord.action)).code == .displayAsleep)
        #expect(mac.posted.count == HeldChord.downEvents)
        #expect(mac.released == HeldChord.released)
    }

    @Test("no retry runs while a call is in the admission section; its own end releases")
    func noRetryInSection() async throws {
        let mac = FakeMac()
        let harness = try ReleaseHarness(mac: mac)
        let executor = harness.executor
        let observed = Observed()
        mac.change {
            $0.onSleep = {
                await observed.record(
                    retry: executor.retryCleanup(now: mac.reading), owed: executor.releaseOwedInput(),
                    next: executor.nextCleanupRetry(at: mac.reading))
            }
        }
        #expect(await executor.perform(try harness.keyboard(HeldChord.action)).result?.eventsPosted == 8)
        #expect(await observed.inSection)
        #expect(mac.released.isEmpty)
    }

    actor Observed {
        private(set) var inSection = false

        func record(retry: OwedRelease?, owed: OwedRelease, next: ContinuousClock.Instant?) {
            guard case .operationInSection? = retry, case .operationInSection = owed, next == nil else { return }
            inSection = true
        }
    }
}
