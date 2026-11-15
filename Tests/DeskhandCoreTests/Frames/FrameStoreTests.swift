import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct FrameIDMintTests {
    @Test func mintsThePrefixAnd22Base64URLCharacters() {
        var counting = ScriptedGenerator(words: [0x0001_0203_0405_0607, 0x0809_0A0B_0C0D_0E0F])
        #expect(FrameID.mint(using: &counting).rawValue == "frm_AAECAwQFBgcICQoLDA0ODw")
        var ones = ScriptedGenerator(words: [.max, .max])
        #expect(FrameID.mint(using: &ones).rawValue == "frm______________________w")
        var zeros = ScriptedGenerator(words: [])
        #expect(FrameID.mint(using: &zeros).rawValue == "frm_AAAAAAAAAAAAAAAAAAAAAA")
    }

    @Test func mintsDistinctValidIDsFromTheSystemGenerator() {
        var generator = SystemRandomNumberGenerator()
        let ids = (0..<1000).map { _ in FrameID.mint(using: &generator).rawValue }
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.utf8.count == 26 && id.hasPrefix(FrameID.mintedPrefix) && FrameID(id) != nil)
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct FrameStoreTests {
    typealias F = FrameFixtures

    @Test func recordsAFrameFromItsCapture() throws {
        var store = FrameStore()
        let capture = F.capture()
        let frame = try store.take(capture, for: F.alpha)
        #expect(frame.scope == F.alpha && frame.displayID == F.mainDisplay)
        #expect(frame.displayConfigGeneration == F.generation && frame.capturedAt == F.t0)
        #expect(frame.geometry == capture.geometry && frame.frontmostApp == F.textEdit && frame.maxAgeMs == 60_000)
        #expect(frame.outputPixelSize == PixelSize(width: 4, height: 4))
        #expect(frame.sha256 == capture.sha256)
        #expect(store.lookup(frame.id, in: F.alpha)?.sha256 == capture.sha256)
        #expect(frame.id.rawValue.hasPrefix("frm_"))
        let live = try #require(store.latest(in: F.alpha, displayID: F.mainDisplay))
        #expect(live.frame == frame && live.pixels == capture.pixels)
        let validated = store.validate(
            frame.id, in: F.alpha, for: .pointer, displayConfigGeneration: F.generation, now: F.t0)
        #expect(validated.frame == frame)
    }

    @Test func hidesAFrameFromEveryOtherScope() throws {
        var store = FrameStore()
        let frame = try store.take(F.capture(), for: F.alpha)
        #expect(store.lookup(frame.id, in: F.alpha) == frame)
        for scope in [F.beta, F.alphaOfOther] {
            #expect(store.lookup(frame.id, in: scope) == nil)
            #expect(store.latest(in: scope, displayID: F.mainDisplay) == nil)
            #expect(store.reason(frame.id, in: scope) == .unknown)
        }
        let never = FrameID("frm_neverMinted")!
        #expect(store.reason(never, in: F.alpha) == .unknown)
    }

    @Test func judgesLatestPerPrincipalHolderAndDisplay() throws {
        var store = FrameStore()
        let first = try store.take(F.capture(), for: F.alpha)
        let otherHolder = try store.take(F.capture(), for: F.beta)
        let otherPrincipal = try store.take(F.capture(), for: F.alphaOfOther)
        let otherDisplay = try store.take(F.capture(display: F.sideDisplay), for: F.alpha)
        func reason(_ id: FrameID, _ scope: FrameScope) -> StaleFrameReason? {
            store.reason(id, in: scope, now: F.t0.adding(milliseconds: 10))
        }
        #expect(reason(first.id, F.alpha) == nil)
        #expect(reason(otherHolder.id, F.beta) == nil)
        #expect(reason(otherPrincipal.id, F.alphaOfOther) == nil)
        #expect(reason(otherDisplay.id, F.alpha) == nil)

        let second = try store.take(F.capture(at: F.t0.adding(milliseconds: 10)), for: F.alpha)
        #expect(reason(first.id, F.alpha) == .notLatest)
        #expect(reason(second.id, F.alpha) == nil)
        #expect(reason(otherHolder.id, F.beta) == nil)
        #expect(reason(otherPrincipal.id, F.alphaOfOther) == nil)
        #expect(reason(otherDisplay.id, F.alpha) == nil)
        #expect(store.lookup(first.id, in: F.alpha) == first)
        #expect(store.latest(in: F.alpha, displayID: F.mainDisplay)?.frame == second)
        #expect(store.liveFrameCount == 4 && store.supersededFrameCount == 1)
    }

    @Test func checksInTheContractOrder() throws {
        var store = FrameStore()
        let old = try store.take(F.capture(), for: F.alpha)
        _ = try store.take(F.capture(), for: F.alpha)
        let late = F.t0.adding(milliseconds: 60_001)
        let changed = DisplayConfigGeneration(8)
        let keyboard = FrameUse.keyboard(frontmostApp: F.finder)
        #expect(store.reason(old.id, in: F.beta, for: keyboard, generation: changed, now: late) == .unknown)
        #expect(store.reason(old.id, in: F.alpha, for: keyboard, generation: changed, now: late) == .displayChanged)
        #expect(store.reason(old.id, in: F.alpha, for: keyboard, now: late) == .notLatest)
        let current = try #require(store.latest(in: F.alpha, displayID: F.mainDisplay)).frame
        #expect(store.reason(current.id, in: F.alpha, for: keyboard, now: late) == .tooOld)
        #expect(store.reason(current.id, in: F.alpha, for: keyboard) == .frontmostChanged)
        #expect(store.reason(current.id, in: F.alpha) == nil)
    }

    @Test(arguments: [(0, true), (60_000, true), (60_001, false), (-1, false)])
    func agesFramesByTheirOwnMaxAge(elapsedMs: Int64, valid: Bool) throws {
        var store = FrameStore()
        let frame = try store.take(F.capture(), for: F.alpha)
        let now = F.t0.adding(milliseconds: elapsedMs)
        #expect(store.reason(frame.id, in: F.alpha, now: now) == (valid ? nil : .tooOld))
        #expect(frame.isTooOld(at: now) == !valid)
    }

    @Test func comparesTheFrontmostAppForKeyboardOnly() throws {
        var store = FrameStore()
        let frame = try store.take(F.capture(frontmost: F.textEdit), for: F.alpha)
        func reason(_ use: FrameUse) -> StaleFrameReason? {
            store.reason(frame.id, in: F.alpha, for: use)
        }
        #expect(reason(.keyboard(frontmostApp: F.textEdit)) == nil)
        #expect(reason(.keyboard(frontmostApp: F.finder)) == .frontmostChanged)
        let renamed = AppRef(bundleID: "com.apple.TextEdit", teamID: "APPLE", name: "TextEdit")
        #expect(reason(.keyboard(frontmostApp: renamed)) == .frontmostChanged)
        #expect(reason(.keyboard(frontmostApp: nil)) == .frontmostChanged)
        #expect(reason(.pointer) == nil)
    }

    @Test func invalidatesEveryFrameOfEveryHolder() throws {
        var store = FrameStore()
        let frames = [
            try store.take(F.capture(), for: F.alpha), try store.take(F.capture(), for: F.beta),
            try store.take(F.capture(), for: F.alpha),
        ]
        let before = store.epoch
        store.invalidateAll()
        #expect(store.epoch != before)
        #expect(store.liveFrameCount == 0 && store.supersededFrameCount == 0)
        for frame in frames {
            #expect(store.reason(frame.id, in: frame.scope) == .unknown)
            #expect(store.lookup(frame.id, in: frame.scope) == nil)
        }
    }

    @Test func discardsACaptureThatStraddledAnInvalidation() throws {
        var store = FrameStore()
        let started = store.epoch
        store.invalidateAll()
        var generator = SeededGenerator(state: 1)
        #expect(throws: FrameRecordError.invalidatedDuringCapture) {
            try store.record(
                F.capture(), for: F.alpha, leaseHolder: nil, startedIn: started, now: F.t0, using: &generator)
        }
        #expect(store.liveFrameCount == 0)
        _ = try store.record(
            F.capture(), for: F.alpha, leaseHolder: nil, startedIn: store.epoch, now: F.t0, using: &generator)
        #expect(store.liveFrameCount == 1)
    }

    @Test func refusesAnInconsistentCapture() {
        var store = FrameStore()
        var mismatched = F.capture()
        mismatched.pixels = F.pixels(PixelSize(width: 3, height: 4))
        var upscaled = F.capture()
        upscaled.downscale = 1.5
        var tooYoung = F.capture()
        tooYoung.maxAgeMs = 4999
        var tooLong = F.capture()
        tooLong.maxAgeMs = 600_001
        var unscaled = F.capture()
        unscaled.pointPixelScale = .nan
        for capture in [mismatched, upscaled, tooYoung, tooLong, unscaled] {
            #expect(throws: FrameRecordError.inconsistentCapture) { try store.take(capture, for: F.alpha) }
        }
        #expect(store.liveFrameCount == 0)
    }

    @Test func mintsAFreshIDWhenTheGeneratorRepeats() throws {
        var store = FrameStore()
        var repeating = ScriptedGenerator(words: [1, 2, 1, 2, 3, 4])
        let first = try store.record(
            F.capture(), for: F.alpha, leaseHolder: nil, startedIn: store.epoch, now: F.t0, using: &repeating)
        let second = try store.record(
            F.capture(), for: F.beta, leaseHolder: nil, startedIn: store.epoch, now: F.t0, using: &repeating)
        var expected = ScriptedGenerator(words: [3, 4])
        let expectedID = FrameID.mint(using: &expected)
        #expect(first.id != second.id && second.id == expectedID)
    }

    @Test func dropsFramesPastTheirMaxAgeWhenRecording() throws {
        var store = FrameStore()
        let old = try store.take(F.capture(maxAgeMs: 5000), for: F.alpha)
        _ = try store.take(F.capture(maxAgeMs: 5000), for: F.alpha)
        let keeper = try store.take(F.capture(maxAgeMs: 600_000), for: F.beta)
        #expect(store.liveFrameCount == 2 && store.supersededFrameCount == 1)
        let later = F.t0.adding(milliseconds: 5001)
        let fresh = try store.take(F.capture(display: F.sideDisplay, at: later), for: F.alpha, now: later)
        #expect(store.liveFrameCount == 2 && store.supersededFrameCount == 0)
        #expect(store.lookup(old.id, in: F.alpha) == nil)
        #expect(store.latest(in: F.alpha, displayID: F.mainDisplay) == nil)
        #expect(store.lookup(keeper.id, in: F.beta) == keeper && store.lookup(fresh.id, in: F.alpha) == fresh)
    }

    @Test func boundsLiveFramesByEvictingTheOldest() throws {
        var store = FrameStore(maxLiveFrames: 2, maxSupersededFrames: 8)
        let holders = (0..<3).map { FrameScope(principal: F.crew, holderID: HolderID("h\($0)")!) }
        let frames = try holders.enumerated().map { index, scope in
            try store.take(F.capture(at: F.t0.adding(milliseconds: Int64(index))), for: scope)
        }
        #expect(store.liveFrameCount == 2)
        #expect(store.reason(frames[0].id, in: holders[0]) == .unknown)
        #expect(store.latest(in: holders[0], displayID: F.mainDisplay) == nil)
        #expect(store.lookup(frames[1].id, in: holders[1]) != nil && store.lookup(frames[2].id, in: holders[2]) != nil)
    }

    @Test func otherHoldersNeverEvictTheLeaseHoldersFrame() throws {
        var store = FrameStore()
        let held = try store.take(F.capture(), for: F.alpha, leaseHolder: F.alpha)
        for index in 0..<(FrameStore.defaultMaxLiveFrames * 2) {
            let scope = FrameScope(principal: F.crew, holderID: HolderID("reader-\(index)")!)
            _ = try store.take(
                F.capture(at: F.t0.adding(milliseconds: Int64(index + 1))), for: scope, leaseHolder: F.alpha)
        }
        #expect(store.liveFrameCount == FrameStore.defaultMaxLiveFrames)
        #expect(store.latest(in: F.alpha, displayID: F.mainDisplay)?.frame == held)
        #expect(store.reason(held.id, in: F.alpha, now: F.t0.adding(milliseconds: 100)) == nil)
    }

    @Test func aScopeOverItsBoundEvictsItsOwnOldest() throws {
        var store = FrameStore(maxLiveFrames: 16, maxLiveFramesPerScope: 2)
        let other = try store.take(F.capture(), for: F.beta)
        let displays = (1...3).map { DisplayID(UInt32(100 + $0)) }
        let frames = try displays.enumerated().map { index, display in
            try store.take(F.capture(display: display, at: F.t0.adding(milliseconds: Int64(index + 1))), for: F.alpha)
        }
        #expect(store.lookup(frames[0].id, in: F.alpha) == nil)
        #expect(store.lookup(frames[1].id, in: F.alpha) != nil && store.lookup(frames[2].id, in: F.alpha) != nil)
        #expect(store.lookup(other.id, in: F.beta) != nil)
    }

    @Test func neverEvictsTheFrameJustRecorded() throws {
        var store = FrameStore(maxLiveFrames: 1, maxSupersededFrames: 0)
        _ = try store.take(F.capture(at: F.t0.adding(milliseconds: 100)), for: F.alpha)
        let older = try store.take(F.capture(at: F.t0), for: F.beta, now: F.t0.adding(milliseconds: 100))
        #expect(store.latest(in: F.beta, displayID: F.mainDisplay)?.frame == older)
        #expect(store.liveFrameCount == 1)
    }

    @Test func boundsSupersededFramesByEvictingTheOldest() throws {
        var store = FrameStore(maxLiveFrames: 4, maxSupersededFrames: 2)
        let frames = try (0..<4).map { index in
            try store.take(F.capture(at: F.t0.adding(milliseconds: Int64(index))), for: F.alpha)
        }
        #expect(store.supersededFrameCount == 2)
        let now = F.t0.adding(milliseconds: 10)
        let reasons = frames.map { store.reason($0.id, in: F.alpha, now: now) }
        #expect(reasons == [.unknown, .notLatest, .notLatest, nil])
    }
}
