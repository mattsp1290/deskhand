import DeskhandCore
import Synchronization
import Testing

/// Contract 11.5 and 13.2: telling the person's input from deskhand's own, and the watchdog's poll.
@Suite("Watchdog: the person at the Mac")
struct PersonActivityTests {
    struct Reading: CustomTestStringConvertible, Sendable {
        let name: String
        let signal: IdleSignal
        /// How long ago deskhand last posted, if it has.
        let ownPostMsAgo: Int64?
        let idleMs: Int64?

        var testDescription: String { name }
    }

    static let readings: [Reading] = [
        Reading(name: "unreadable", signal: .unavailable, ownPostMsAgo: 10, idleMs: nil),
        Reading(name: "separated by the platform", signal: .personOnly(.seconds(5)), ownPostMsAgo: 1, idleMs: 5000),
        Reading(name: "separated, clock skew", signal: .personOnly(.milliseconds(-3)), ownPostMsAgo: nil, idleMs: 0),
        Reading(name: "any origin, nothing posted", signal: .anyOrigin(.seconds(2)), ownPostMsAgo: nil, idleMs: 2000),
        Reading(
            name: "any origin, input after deskhand's post", signal: .anyOrigin(.milliseconds(200)), ownPostMsAgo: 500,
            idleMs: 200),
        Reading(
            name: "any origin, deskhand's post is the latest input", signal: .anyOrigin(.milliseconds(500)),
            ownPostMsAgo: 500, idleMs: nil),
        Reading(
            name: "any origin, inside the echo tolerance", signal: .anyOrigin(.milliseconds(460)), ownPostMsAgo: 500,
            idleMs: nil),
        Reading(
            name: "any origin, at the end of the echo tolerance", signal: .anyOrigin(.milliseconds(450)),
            ownPostMsAgo: 500, idleMs: nil),
        Reading(
            name: "any origin, just past the echo tolerance", signal: .anyOrigin(.milliseconds(449)),
            ownPostMsAgo: 500, idleMs: 449),
        Reading(
            name: "any origin, the signal has not caught up with deskhand's post",
            signal: .anyOrigin(.milliseconds(2000)), ownPostMsAgo: 1000, idleMs: nil),
        Reading(
            name: "any origin, deskhand's post older than the lookback", signal: .anyOrigin(.milliseconds(4000)),
            ownPostMsAgo: 4000, idleMs: 4000),
    ]

    @Test("own posts are discounted only when they can be told apart", arguments: readings)
    func rule(reading: Reading) {
        let now = WatchdogFixture.at(60_000).monotonic
        let idle = PersonIdleRule.personIdle(
            reading.signal, lastOwnPost: reading.ownPostMsAgo.map { now.advanced(by: .milliseconds(-$0)) }, now: now,
            echoTolerance: .milliseconds(50), lookback: .milliseconds(ContractConstants.userActivityLookbackMs))
        #expect(idle == reading.idleMs.map { .milliseconds($0) })
    }

    @Test(
        "the echo tolerance changes what is reported, never whether it is activity",
        arguments: [Int64(0), 50, 500, 5000])
    func toleranceKeepsTheVerdict(toleranceMs: Int64) {
        let now = WatchdogFixture.at(60_000).monotonic
        let lookback = Duration.milliseconds(ContractConstants.userActivityLookbackMs)
        func isActivity(_ idle: Duration?) -> Bool { idle.map { $0 < lookback } ?? true }
        for idleMs in stride(from: Int64(0), through: 6000, by: 50) {
            for ownPostMsAgo in [nil] + stride(from: Int64(0), through: 6000, by: 250).map(Optional.some) {
                let reading = IdleSignal.anyOrigin(.milliseconds(idleMs))
                let lastOwnPost = ownPostMsAgo.map { now.advanced(by: .milliseconds(-$0)) }
                let strict = PersonIdleRule.personIdle(
                    reading, lastOwnPost: lastOwnPost, now: now, echoTolerance: .zero, lookback: lookback)
                let tolerant = PersonIdleRule.personIdle(
                    reading, lastOwnPost: lastOwnPost, now: now, echoTolerance: .milliseconds(toleranceMs),
                    lookback: lookback)
                #expect(
                    isActivity(strict) == isActivity(tolerant),
                    "idle \(idleMs), post \(String(describing: ownPostMsAgo))")
            }
        }
    }

    @Test("an idle time just short of the lookback stays under it")
    func roundsDown() {
        let source = PersonActivitySource(
            signal: Fixed(.personOnly(.microseconds(2_999_900))), posts: PostTimestampRecorder(),
            clock: { WatchdogFixture.t0.monotonic })
        #expect(source.idleMilliseconds() == 2999)
    }

    @Test("the recorder keeps the latest post however late a report arrives")
    func recorderNeverMovesBack() {
        let recorder = PostTimestampRecorder()
        #expect(recorder.lastPostedEvent == nil)
        recorder.didPostEvent(at: WatchdogFixture.at(20).monotonic)
        recorder.didPostEvent(at: WatchdogFixture.at(10).monotonic)
        #expect(recorder.lastPostedEvent == WatchdogFixture.at(20).monotonic)
    }

    /// deskhand's events during one effect, in milliseconds from its start.
    enum Pattern: String, CaseIterable, Sendable {
        /// A key down and up every 4 ms.
        case typing
        /// A button down, a move every 16 ms, the button up.
        case drag
        /// Three modifiers and a key down, held 500 ms, then up.
        case chord

        var posts: [Int64] {
            switch self {
            case .typing: Array(stride(from: 0, through: 1200, by: 4))
            case .drag: Array(stride(from: 0, through: 1000, by: 16))
            case .chord: [0, 0, 0, 0, 500, 500, 500, 500]
            }
        }

        var end: Int64 { posts.last! }
    }

    /// Runs `pattern` from t0 with the watchdog driven at its own wakeups. The person touches the Mac
    /// at `personAt`. Returns the interruptions and when they arrived.
    static func watch(
        _ pattern: Pattern, kind: FakeHID.Kind, personAt: Int64?
    ) async -> [(Interruption, Int64)] {
        let clock = ManualScheduler()
        let hid = FakeHID(kind) { clock.now }
        let posts = OwnPosts(hid: hid)
        let executor = FakeExecutor(clock: clock)
        let watchdog = Watchdog(
            owner: FakeDesk(clock: clock), executor: executor,
            activity: PersonActivitySource(signal: hid, posts: posts.recorder) { clock.now }, scheduler: clock)
        var events = pattern.posts.map { (at: $0, person: false) }
        if let personAt { events.append((personAt, true)) }
        events.sort { $0.at < $1.at }

        await watchdog.executionDidChange(executing: true)
        var wakeup = await watchdog.evaluate()
        while clock.elapsedMs <= pattern.end, await executor.interrupts.isEmpty {
            let nextEvent = events.first.map { WatchdogFixture.at($0.at).monotonic }
            let next = [nextEvent, wakeup].compactMap { $0 }.min()!
            clock.advance(to: next)
            while let event = events.first, WatchdogFixture.at(event.at).monotonic <= clock.now {
                events.removeFirst()
                if event.person { hid.personInput(at: clock.now) } else { posts.post(at: clock.now) }
            }
            if let due = wakeup, due <= clock.now { wakeup = await watchdog.evaluate() }
        }
        return await executor.interrupts
    }

    @Test("the person's input during an effect stops it within 250 ms", arguments: Pattern.allCases)
    func personIntervenes(pattern: Pattern) async {
        let personAt: Int64 = 333
        let interrupts = await Self.watch(pattern, kind: .personOnly, personAt: personAt)
        let first = interrupts.first
        guard case .userActive(let idleMs)? = first?.0, let at = first?.1 else {
            Issue.record("not stopped for the person: \(interrupts)")
            return
        }
        #expect(at - personAt <= Int64(ContractConstants.userActivityAbortMs))
        #expect(at - personAt <= Int64(ContractConstants.userActivityPollMs))
        #expect(Int64(idleMs) == at - personAt)
    }

    @Test("deskhand's own events do not count", arguments: Pattern.allCases)
    func ownPostsDoNotCount(pattern: Pattern) async {
        #expect(await Self.watch(pattern, kind: .personOnly, personAt: nil).isEmpty)
    }

    @Test("a signal that cannot tell deskhand's events apart counts as activity", arguments: Pattern.allCases)
    func inseparable(pattern: Pattern) async {
        let interrupts = await Self.watch(pattern, kind: .anyOrigin, personAt: nil)
        #expect(interrupts.first?.0 == .userActive(idleMs: 0))
        #expect(interrupts.first.map { $0.1 <= Int64(ContractConstants.userActivityPollMs) } == true)
    }

    @Test("an unreadable signal counts as activity, with idle_ms 0")
    func unreadable() async {
        let interrupts = await Self.watch(.chord, kind: .unavailable, personAt: nil)
        #expect(interrupts.first?.0 == .userActive(idleMs: 0))
        #expect(interrupts.first?.1 == 0)
    }

    @Test("the person is polled only while an effect executes")
    func pollsOnlyWhileExecuting() async {
        let clock = ManualScheduler()
        let hid = FakeHID(.personOnly) { clock.now }
        let executor = FakeExecutor(clock: clock)
        let watchdog = Watchdog(
            owner: FakeDesk(clock: clock), executor: executor,
            activity: PersonActivitySource(signal: hid, posts: PostTimestampRecorder()) { clock.now },
            scheduler: clock)
        #expect(await watchdog.evaluate() == WatchdogFixture.at(1000).monotonic)
        #expect(hid.reads == 0)

        await watchdog.executionDidChange(executing: true)
        #expect(hid.reads == 1)
        #expect(await watchdog.evaluate() == WatchdogFixture.at(100).monotonic)
        clock.advance(byMilliseconds: 100)
        _ = await watchdog.evaluate()
        #expect(hid.reads == 2)

        await watchdog.executionDidChange(executing: false)
        #expect(await watchdog.evaluate() == WatchdogFixture.at(1000).monotonic)
        #expect(hid.reads == 2)
        #expect(await executor.interruptions.isEmpty)
    }
}

struct Fixed: IdleSignalSource {
    let signal: IdleSignal

    init(_ signal: IdleSignal) { self.signal = signal }

    func idleSignal() -> IdleSignal { signal }
}
