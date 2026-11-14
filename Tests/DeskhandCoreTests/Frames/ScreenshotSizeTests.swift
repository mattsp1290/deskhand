import DeskhandCore
import Testing

@Suite struct ScreenshotSizeTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let source: (Int, Int)
        let maxLongEdge: Int
        let output: (Int, Int)
        var testDescription: String { "\(source.0)x\(source.1) L=\(maxLongEdge)" }
    }

    /// The contract 7 table (0.10-draft), then edges: exact limits, one-pixel sides, huge and portrait
    /// displays, and the size with the most visual tokens by patches that the rule can produce.
    static let rows: [Row] = [
        Row(source: (3456, 2234), maxLongEdge: 2576, output: (2355, 1522)),
        Row(source: (3024, 1964), maxLongEdge: 2576, output: (2350, 1526)),
        Row(source: (5120, 2880), maxLongEdge: 2576, output: (2525, 1420)),
        Row(source: (2560, 1440), maxLongEdge: 2576, output: (2525, 1420)),
        Row(source: (3456, 2234), maxLongEdge: 1568, output: (1568, 1013)),
        Row(source: (6016, 3384), maxLongEdge: 2576, output: (2525, 1420)),
        Row(source: (3384, 6016), maxLongEdge: 2576, output: (1420, 2525)),
        Row(source: (6016, 3384), maxLongEdge: 256, output: (256, 144)),
        Row(source: (7680, 4320), maxLongEdge: 2576, output: (2525, 1420)),
        Row(source: (2576, 1455), maxLongEdge: 2576, output: (2520, 1423)),
        Row(source: (2500, 1500), maxLongEdge: 2576, output: (2445, 1467)),
        Row(source: (1937, 1937), maxLongEdge: 2576, output: (1894, 1894)),
        Row(source: (1894, 1894), maxLongEdge: 2576, output: (1894, 1894)),
        Row(source: (1541, 2328), maxLongEdge: 2576, output: (1541, 2328)),
        Row(source: (2577, 1), maxLongEdge: 2576, output: (2576, 1)),
        Row(source: (1, 2577), maxLongEdge: 2576, output: (1, 2576)),
        Row(source: (1, 1), maxLongEdge: 256, output: (1, 1)),
        Row(source: (1, 100_000), maxLongEdge: 2576, output: (1, 2576)),
        Row(source: (100_000, 1), maxLongEdge: 256, output: (256, 1)),
        Row(source: (256, 256), maxLongEdge: 256, output: (256, 256)),
    ]

    /// Contract 7: every output stays under `MAX_VISUAL_TOKENS` counted both ways, and the largest
    /// count by patches the rule can produce is 4704.
    @Test func everyOutputStaysUnderTheTokenCap() throws {
        var mostPatches = 0
        for width in stride(from: 1, through: 6000, by: 7) {
            for height in [1, 28, 29, 1393, 1455, 1964, 2234, 2328, 2577, 3384, 6016] {
                let output = try ScreenshotSize(source: PixelSize(width: width, height: height)).output
                #expect(output.width * output.height <= ContractConstants.maxPixels)
                #expect(output.width * output.height * 1 <= ContractConstants.maxVisualTokens * 750)
                mostPatches = max(mostPatches, ScreenshotSize.visualTokens(output))
            }
        }
        #expect(mostPatches <= ContractConstants.maxVisualTokens)
        #expect(ScreenshotSize.visualTokens(PixelSize(width: 1541, height: 2328)) == 4704)
        #expect(ScreenshotSize.visualTokens(PixelSize(width: 28, height: 29)) == 2)
    }

    @Test(arguments: rows)
    func matchesTheContractAndItsEdges(row: Row) throws {
        let size = try ScreenshotSize(
            source: PixelSize(width: row.source.0, height: row.source.1), maxLongEdge: row.maxLongEdge)
        #expect(size.output == PixelSize(width: row.output.0, height: row.output.1))
        #expect(size.downscale > 0 && size.downscale <= 1)
    }

    @Test func reportsTheUnflooredScale() throws {
        #expect(try ScreenshotSize(source: PixelSize(width: 1894, height: 1894)).downscale == 1)
        #expect(try ScreenshotSize(source: PixelSize(width: 2560, height: 1440)).downscale == 0.9865633743792979)
        #expect(try ScreenshotSize(source: PixelSize(width: 3456, height: 2234)).downscale == 0.6817070194446376)
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
        let size = try ScreenshotSize(source: PixelSize(width: 6016, height: 2000), maxLongEdge: maxLongEdge)
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
