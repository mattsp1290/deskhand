import DeskhandCore
import Testing

@Suite struct ScreenshotSizeTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let source: (Int, Int)
        let maxLongEdge: Int
        let output: (Int, Int)
        var testDescription: String { "\(source.0)x\(source.1) L=\(maxLongEdge)" }
    }

    /// The contract 7 table, then edges: exact limits, one-pixel sides, huge and portrait displays.
    static let rows: [Row] = [
        Row(source: (3456, 2234), maxLongEdge: 2576, output: (2408, 1556)),
        Row(source: (3024, 1964), maxLongEdge: 2576, output: (2402, 1560)),
        Row(source: (5120, 2880), maxLongEdge: 2576, output: (2576, 1449)),
        Row(source: (2560, 1440), maxLongEdge: 2576, output: (2560, 1440)),
        Row(source: (3456, 2234), maxLongEdge: 1568, output: (1568, 1013)),
        Row(source: (6016, 3384), maxLongEdge: 2576, output: (2576, 1449)),
        Row(source: (3384, 6016), maxLongEdge: 2576, output: (1449, 2576)),
        Row(source: (6016, 3384), maxLongEdge: 256, output: (256, 144)),
        Row(source: (7680, 4320), maxLongEdge: 2576, output: (2576, 1449)),
        Row(source: (2576, 1455), maxLongEdge: 2576, output: (2576, 1455)),
        Row(source: (2500, 1500), maxLongEdge: 2576, output: (2500, 1500)),
        Row(source: (2576, 1456), maxLongEdge: 2576, output: (2575, 1455)),
        Row(source: (1937, 1937), maxLongEdge: 2576, output: (1936, 1936)),
        Row(source: (2577, 1), maxLongEdge: 2576, output: (2576, 1)),
        Row(source: (1, 2577), maxLongEdge: 2576, output: (1, 2576)),
        Row(source: (1, 1), maxLongEdge: 256, output: (1, 1)),
        Row(source: (1, 100_000), maxLongEdge: 2576, output: (1, 2576)),
        Row(source: (100_000, 1), maxLongEdge: 256, output: (256, 1)),
        Row(source: (256, 256), maxLongEdge: 256, output: (256, 256)),
    ]

    @Test(arguments: rows)
    func matchesTheContractAndItsEdges(row: Row) throws {
        let size = try ScreenshotSize(
            source: PixelSize(width: row.source.0, height: row.source.1), maxLongEdge: row.maxLongEdge)
        #expect(size.output == PixelSize(width: row.output.0, height: row.output.1))
        #expect(size.downscale > 0 && size.downscale <= 1)
    }

    @Test func reportsTheUnflooredScale() throws {
        #expect(try ScreenshotSize(source: PixelSize(width: 2560, height: 1440)).downscale == 1)
        #expect(try ScreenshotSize(source: PixelSize(width: 5120, height: 2880)).downscale == 0.503125)
        #expect(try ScreenshotSize(source: PixelSize(width: 1, height: 1), maxLongEdge: 256).downscale == 1)
    }

    @Test(arguments: [Int.min, -1, 0, 255, 2577, 4096, Int.max])
    func refusesAMaxLongEdgeOutsideTheContractRange(maxLongEdge: Int) {
        #expect(throws: ScreenshotSizingError.maxLongEdgeOutOfRange(maxLongEdge)) {
            try ScreenshotSize(source: PixelSize(width: 100, height: 100), maxLongEdge: maxLongEdge)
        }
        let error = ScreenshotSizingError.maxLongEdgeOutOfRange(maxLongEdge).argumentError
        #expect(error?.pointer == JSONPointer(["max_long_edge"]))
    }

    @Test(arguments: [256, 257, 2575, 2576])
    func acceptsTheRangeEnds(maxLongEdge: Int) throws {
        let size = try ScreenshotSize(source: PixelSize(width: 6016, height: 3384), maxLongEdge: maxLongEdge)
        #expect(size.output.width == maxLongEdge)
    }

    @Test(arguments: [(0, 10), (10, 0), (-1, 10), (0, 0)])
    func refusesAnEmptySourceAsAFault(width: Int, height: Int) {
        let source = PixelSize(width: width, height: height)
        #expect(throws: ScreenshotSizingError.emptySource(source)) { try ScreenshotSize(source: source) }
        #expect(ScreenshotSizingError.emptySource(source).argumentError == nil)
    }

    /// Never upscales, never breaks either limit after flooring, never shrinks below one pixel, and
    /// keeps every side within one pixel of the exact scaled size.
    @Test func holdsItsLimitsAcrossASweep() throws {
        var generator = SeededGenerator(state: 42)
        let edges = [256, 512, 1024, 1568, 2000, 2576]
        for _ in 0..<20_000 {
            let source = PixelSize(
                width: Int.random(in: 1...16_384, using: &generator),
                height: Int.random(in: 1...16_384, using: &generator))
            let maxLongEdge = edges.randomElement(using: &generator)!
            let size = try ScreenshotSize(source: source, maxLongEdge: maxLongEdge)
            let output = size.output
            #expect(output.width >= 1 && output.height >= 1)
            #expect(output.width <= source.width && output.height <= source.height)
            #expect(max(output.width, output.height) <= maxLongEdge)
            #expect(output.width * output.height <= ContractConstants.maxPixels)
            #expect(Double(output.width) >= (Double(source.width) * size.downscale).rounded(.down) - 1)
            #expect(Double(output.height) >= (Double(source.height) * size.downscale).rounded(.down) - 1)
        }
    }
}
