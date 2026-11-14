import DeskhandCore
import Testing

@Suite struct FrameGeometryTests {
    typealias F = FrameFixtures

    /// The contract 8.2 example: a 3456 x 2234 Retina display at 1728 x 1117 points.
    static let retina = F.geometry(
        GlobalRect(x: 0, y: 0, width: 1728, height: 1117), PixelSize(width: 2408, height: 1556))
    /// A 4K display at scale 2 left of and above the main display, downscaled to 2576 x 1449.
    static let leftOfMain = F.geometry(
        GlobalRect(x: -1920, y: -300, width: 1920, height: 1080), PixelSize(width: 2576, height: 1449))
    /// A 1440 x 900 point display at a non-integer scale of 1.5.
    static let scaled = F.geometry(
        GlobalRect(x: 0, y: 0, width: 1440, height: 900), PixelSize(width: 2160, height: 1350))

    @Test func mapsTheContractExample() {
        let point = Self.retina.globalPoint(for: FramePoint(x: 1204, y: 778))
        #expect(abs(point.x - 864.359) < 0.0005)
        #expect(abs(point.y - 558.859) < 0.0005)
    }

    @Test func mapsToPixelCentresWithNegativeOrigins() {
        let first = Self.leftOfMain.globalPoint(for: FramePoint(x: 0, y: 0))
        #expect(first == GlobalPoint(x: -1920 + 0.5 * 1920 / 2576, y: -300 + 0.5 * 1080 / 1449))
        let last = Self.leftOfMain.globalPoint(for: FramePoint(x: 2575, y: 1448))
        #expect(last == GlobalPoint(x: -1920 + 2575.5 * 1920 / 2576, y: -300 + 1448.5 * 1080 / 1449))
        #expect(last.x < 0 && last.y < 780)
    }

    @Test func mapsAtANonIntegerScale() {
        let first = Self.scaled.globalPoint(for: FramePoint(x: 0, y: 0))
        #expect(abs(first.x - 1.0 / 3) < 1e-12 && abs(first.y - 1.0 / 3) < 1e-12)
        let last = Self.scaled.globalPoint(for: FramePoint(x: 2159, y: 1349))
        #expect(abs(last.x - (1440 - 1.0 / 3)) < 1e-9 && abs(last.y - (900 - 1.0 / 3)) < 1e-9)
    }

    @Test func clampsToTheDisplayWhenTheCaptureOverhangsIt() {
        let geometry = F.geometry(
            GlobalRect(x: -1, y: -1, width: 102, height: 52), PixelSize(width: 102, height: 52),
            display: GlobalRect(x: 0, y: 0, width: 100, height: 50))
        #expect(geometry.globalPoint(for: FramePoint(x: 0, y: 0)) == GlobalPoint(x: 0, y: 0))
        let far = geometry.globalPoint(for: FramePoint(x: 101, y: 51))
        #expect(far == GlobalPoint(x: Double(100).nextDown, y: Double(50).nextDown))
        #expect(geometry.globalPoint(for: FramePoint(x: 50, y: 25)) == GlobalPoint(x: 49.5, y: 24.5))
    }

    @Test(arguments: [retina, leftOfMain, scaled])
    func roundTripsEveryEdgePixel(geometry: FrameGeometry) {
        let size = geometry.outputPixelSize
        var points: [FramePoint] = []
        for x in [0, 1, size.width / 2, size.width - 2, size.width - 1] {
            for y in [0, 1, size.height / 2, size.height - 2, size.height - 1] {
                points.append(FramePoint(x: x, y: y))
            }
        }
        for point in points {
            #expect(geometry.framePoint(for: geometry.globalPoint(for: point)) == point)
        }
    }

    @Test func reportsAPointerOutsideTheFrameAsNil() {
        let geometry = Self.leftOfMain
        #expect(geometry.framePoint(for: GlobalPoint(x: -1920, y: -300)) == FramePoint(x: 0, y: 0))
        #expect(geometry.framePoint(for: GlobalPoint(x: 0, y: 0)) == nil)
        #expect(geometry.framePoint(for: GlobalPoint(x: -0.001, y: 779.99)) == FramePoint(x: 2575, y: 1448))
        #expect(geometry.framePoint(for: GlobalPoint(x: -1920.001, y: 0)) == nil)
        #expect(geometry.framePoint(for: GlobalPoint(x: .nan, y: 0)) == nil)
        #expect(geometry.framePoint(for: GlobalPoint(x: -.infinity, y: 0)) == nil)
    }

    @Test func decidesWhatIsInTheFrame() {
        let size = Self.retina.outputPixelSize
        let inside = [FramePoint(x: 0, y: 0), FramePoint(x: 2407, y: 1555)]
        #expect(inside.allSatisfy(Self.retina.contains))
        let outside = [
            FramePoint(x: -1, y: 0), FramePoint(x: 0, y: -1), FramePoint(x: 2408, y: 0), FramePoint(x: 0, y: 1556),
            FramePoint(x: 65_535, y: -65_536),
        ]
        #expect(!outside.contains(where: Self.retina.contains))
        #expect(Self.retina.outOfFrame(inside) == nil)
        #expect(
            Self.retina.outOfFrame(inside + outside) == .outOfFrame(pointIndex: 2, outputPixelSize: size))
        #expect(Self.retina.outOfFrame([]) == nil)
    }

    @Test func convertsScrollDeltasWithTheFrameRatio() {
        let delta = Self.scaled.globalDelta(dx: -30, dy: 300)
        #expect(delta.dx == -20 && delta.dy == 200)
    }

    @Test func refusesUnusableGeometry() {
        let rect = GlobalRect(x: 0, y: 0, width: 10, height: 10)
        let size = PixelSize(width: 10, height: 10)
        #expect(
            FrameGeometry(captureRect: rect, outputPixelSize: PixelSize(width: 0, height: 10), displayBounds: rect)
                == nil)
        let flat = GlobalRect(x: 0, y: 0, width: 0, height: 10)
        #expect(FrameGeometry(captureRect: flat, outputPixelSize: size, displayBounds: rect) == nil)
        let infinite = GlobalRect(x: .infinity, y: 0, width: 10, height: 10)
        #expect(FrameGeometry(captureRect: rect, outputPixelSize: size, displayBounds: infinite) == nil)
        #expect(FrameGeometry(captureRect: rect, outputPixelSize: size, displayBounds: rect) != nil)
    }
}
