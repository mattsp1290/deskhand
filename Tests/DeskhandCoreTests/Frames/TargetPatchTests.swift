import DeskhandCore
import Testing

@Suite struct TargetPatchTests {
    typealias F = FrameFixtures

    /// Two frame pixels per point, origin left of and above the main display.
    static let geometry = F.geometry(
        GlobalRect(x: -1000, y: -500, width: 1000, height: 500), PixelSize(width: 2000, height: 1000))

    @Test func cutsAFullPatchAroundAnInteriorTarget() throws {
        let patch = try #require(Self.geometry.targetPatch(around: FramePoint(x: 1000, y: 500)))
        #expect(patch.columns == 968..<1032 && patch.rows == 468..<532)
        #expect(patch.pixelCount == 64 * 64)
        #expect(patch.globalRect == GlobalRect(x: -516, y: -266, width: 32, height: 32))
        #expect(patch.center == FramePoint(x: 1000, y: 500))
    }

    @Test func clipsAtTheFrameEdges() throws {
        let topLeft = try #require(Self.geometry.targetPatch(around: FramePoint(x: 10, y: 5)))
        #expect(topLeft.columns == 0..<42 && topLeft.rows == 0..<37)
        #expect(topLeft.globalRect == GlobalRect(x: -1000, y: -500, width: 21, height: 18.5))
        let bottomRight = try #require(Self.geometry.targetPatch(around: FramePoint(x: 1999, y: 999)))
        #expect(bottomRight.columns == 1967..<2000 && bottomRight.rows == 967..<1000)
        #expect(bottomRight.globalRect == GlobalRect(x: -16.5, y: -16.5, width: 16.5, height: 16.5))
    }

    @Test func coversATinyFrameWhole() throws {
        let tiny = F.geometry(GlobalRect(x: 0, y: 0, width: 1, height: 1), PixelSize(width: 1, height: 1))
        let patch = try #require(tiny.targetPatch(around: FramePoint(x: 0, y: 0)))
        #expect(patch.columns == 0..<1 && patch.rows == 0..<1 && patch.pixelCount == 1)
    }

    @Test func hasNoPatchOutsideTheFrame() {
        #expect(Self.geometry.targetPatch(around: FramePoint(x: 2000, y: 0)) == nil)
        #expect(Self.geometry.targetPatch(around: FramePoint(x: 0, y: -1)) == nil)
    }

    @Test func toleratesSixteenPerChannelButNotSeventeen() throws {
        let patch = try #require(Self.geometry.targetPatch(around: FramePoint(x: 1000, y: 500)))
        let original = F.pixels(Self.geometry.outputPixelSize, fill: 100)
        let within = F.pixels(Self.geometry.outputPixelSize, fill: 116)
        let beyond = F.pixels(Self.geometry.outputPixelSize, fill: 117)
        let below = F.pixels(Self.geometry.outputPixelSize, fill: 84)
        #expect(patch.compare(original: original, current: original) == .unchanged)
        #expect(patch.compare(original: original, current: within) == .unchanged)
        #expect(patch.compare(original: original, current: below) == .unchanged)
        #expect(patch.compare(original: original, current: beyond) == .changed)
    }

    /// 2% of a full 4096-pixel patch is 81.92: 81 changed pixels pass, 82 do not.
    @Test(arguments: [(81, PatchVerdict.unchanged), (82, .changed)])
    func countsChangedPixelsAgainstTwoPercent(changedPixels: Int, verdict: PatchVerdict) throws {
        let size = PixelSize(width: 64, height: 64)
        let geometry = F.geometry(GlobalRect(x: 0, y: 0, width: 64, height: 64), size)
        let patch = try #require(geometry.targetPatch(around: FramePoint(x: 32, y: 32)))
        #expect(patch.pixelCount == 4096)
        let original = F.pixels(size, fill: 0)
        var rgb = original.rgb
        for pixel in 0..<changedPixels { rgb[pixel * 3 + pixel % 3] = 17 }
        let current = try #require(FramePixels(size: size, rgb: rgb))
        #expect(patch.compare(original: original, current: current) == verdict)
    }

    @Test func countsOnlyPixelsInsideThePatch() throws {
        let size = Self.geometry.outputPixelSize
        let patch = try #require(Self.geometry.targetPatch(around: FramePoint(x: 1000, y: 500)))
        let original = F.pixels(size, fill: 0)
        var rgb = original.rgb
        for y in 0..<size.height where !patch.rows.contains(y) {
            for x in 0..<size.width { rgb[(y * size.width + x) * 3] = 255 }
        }
        let current = try #require(FramePixels(size: size, rgb: rgb))
        #expect(patch.compare(original: original, current: current) == .unchanged)
    }

    @Test func acceptsAPatchSizedRecapture() throws {
        let size = Self.geometry.outputPixelSize
        let patch = try #require(Self.geometry.targetPatch(around: FramePoint(x: 10, y: 5)))
        var frame = Array(repeating: UInt8(0), count: size.width * size.height * 3)
        frame[((5 * size.width) + 10) * 3] = 200
        let original = try #require(FramePixels(size: size, rgb: frame))
        let patchSize = PixelSize(width: 42, height: 37)
        var cut = Array(repeating: UInt8(0), count: 42 * 37 * 3)
        cut[((5 * 42) + 10) * 3] = 200
        #expect(
            patch.compare(original: original, current: try #require(FramePixels(size: patchSize, rgb: cut)))
                == .unchanged)
        let blank = F.pixels(patchSize, fill: 255)
        #expect(patch.compare(original: original, current: blank) == .changed)
    }

    @Test func cannotCompareMismatchedSizes() throws {
        let patch = try #require(Self.geometry.targetPatch(around: FramePoint(x: 1000, y: 500)))
        let original = F.pixels(Self.geometry.outputPixelSize)
        #expect(patch.compare(original: original, current: F.pixels(PixelSize(width: 63, height: 64))) == .unknown)
        #expect(patch.compare(original: F.pixels(PixelSize(width: 64, height: 64)), current: original) == .unknown)
    }

    @Test func refusesPixelBuffersOfTheWrongLength() {
        let size = PixelSize(width: 2, height: 2)
        #expect(FramePixels(size: size, rgb: Array(repeating: 0, count: 12)) != nil)
        #expect(FramePixels(size: size, rgb: Array(repeating: 0, count: 11)) == nil)
        #expect(FramePixels(size: PixelSize(width: 0, height: 0), rgb: []) == nil)
        #expect(FramePixels(size: PixelSize(width: Int.max, height: 2), rgb: []) == nil)
    }

    @Test func expressesTheChangedFractionExactly() {
        #expect(ContractConstants.patchMaxChangedFraction == 1.0 / 50)
        #expect(ContractConstants.patchSize == 64 && ContractConstants.patchChannelTolerance == 16)
    }
}

@Suite struct TargetPatchCheckTests {
    typealias F = FrameFixtures

    actor RecordingVerifier: TargetPatchVerifier {
        let answer: @Sendable ([TargetPatch]) -> [PatchVerdict]
        private(set) var calls: [[TargetPatch]] = []

        init(_ answer: @escaping @Sendable ([TargetPatch]) -> [PatchVerdict]) { self.answer = answer }

        func verify(_ frame: LiveFrame, patches: [TargetPatch]) async -> [PatchVerdict] {
            calls.append(patches)
            return answer(patches)
        }
    }

    static func liveFrame() throws -> LiveFrame {
        var store = FrameStore()
        let frame = try store.take(F.capture(size: PixelSize(width: 200, height: 100)), for: F.alpha)
        return try #require(store.latest(in: F.alpha, displayID: frame.displayID))
    }

    static let drag: JSONValue = [
        "type": "drag", "path": [["x": 10, "y": 10], ["x": 50, "y": 50], ["x": 190, "y": 90]],
    ]

    @Test func checksOneTargetForMoveClickAndScroll() async throws {
        let actions: [JSONValue] = [
            ["type": "move", "x": 5, "y": 6], ["type": "click", "x": 5, "y": 6],
            ["type": "scroll", "x": 5, "y": 6, "dy": 3],
        ]
        for action in actions {
            let verifier = RecordingVerifier { $0.map { _ in .unchanged } }
            let reason = await TargetPatchCheck.run(try F.pointer(action), on: try Self.liveFrame(), verifier: verifier)
            #expect(reason == nil)
            #expect(await verifier.calls.map { $0.map(\.center) } == [[FramePoint(x: 5, y: 6)]])
        }
    }

    @Test func checksTheFirstAndLastPointOfADrag() async throws {
        let action = try F.pointer(Self.drag)
        #expect(action.patchTargets.map(\.pointIndex) == [0, 2])
        let verifier = RecordingVerifier { $0.map { _ in .unchanged } }
        #expect(await TargetPatchCheck.run(action, on: try Self.liveFrame(), verifier: verifier) == nil)
        #expect(
            await verifier.calls.map { $0.map(\.center) } == [[FramePoint(x: 10, y: 10), FramePoint(x: 190, y: 90)]])
    }

    @Test(arguments: [
        ([PatchVerdict.changed, .unchanged], 0), ([.unchanged, .changed], 2), ([.changed, .changed], 0),
        ([.unknown, .unchanged], 0), ([.unchanged, .unknown], 2),
    ])
    func namesTheFirstPatchThatDidNotVerify(verdicts: [PatchVerdict], pointIndex: Int) async throws {
        let verifier = RecordingVerifier { _ in verdicts }
        let reason = await TargetPatchCheck.run(try F.pointer(Self.drag), on: try Self.liveFrame(), verifier: verifier)
        #expect(reason == .pixelsChanged(pointIndex: pointIndex))
    }

    @Test(arguments: [[PatchVerdict](), [.unchanged], [.unchanged, .unchanged, .unchanged]])
    func failsClosedOnAMiscountedAnswer(verdicts: [PatchVerdict]) async throws {
        let verifier = RecordingVerifier { _ in verdicts }
        let reason = await TargetPatchCheck.run(try F.pointer(Self.drag), on: try Self.liveFrame(), verifier: verifier)
        #expect(reason == .pixelsChanged(pointIndex: 0))
    }

    @Test func failsClosedOnATargetOutsideTheFrame() async throws {
        let verifier = RecordingVerifier { $0.map { _ in .unchanged } }
        let drag: JSONValue = ["type": "drag", "path": [["x": 10, "y": 10], ["x": 200, "y": 50]]]
        let reason = await TargetPatchCheck.run(try F.pointer(drag), on: try Self.liveFrame(), verifier: verifier)
        #expect(reason == .pixelsChanged(pointIndex: 1))
        #expect(await verifier.calls.isEmpty)
    }
}
