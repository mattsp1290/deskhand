import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// ScreenCaptureKit capture plus pixel statistics. Images are reduced to numbers; no pixels are
/// written to results.
public enum CaptureTools {
  public static func shareableContent() async throws -> SCShareableContent {
    try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  }

  /// Captures `filter` at the display's native pixel size, in sRGB, without the cursor.
  public static func capture(_ filter: SCContentFilter) async throws -> CGImage {
    let info = SCShareableContent.info(for: filter)
    let config = SCStreamConfiguration()
    config.width = max(1, Int((info.contentRect.width * CGFloat(info.pointPixelScale)).rounded()))
    config.height = max(
      1, Int((info.contentRect.height * CGFloat(info.pointPixelScale)).rounded()))
    config.showsCursor = false
    config.colorSpaceName = CGColorSpace.sRGB
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  }

  public static func filterInfo(_ filter: SCContentFilter) -> JSON {
    let info = SCShareableContent.info(for: filter)
    return .obj([
      ("content_rect", Geometry.json(info.contentRect)),
      ("point_pixel_scale", .double(Double(info.pointPixelScale))),
    ])
  }

  public static func errorJSON(_ error: any Error) -> JSON {
    let ns = error as NSError
    return .obj([
      ("domain", .string(ns.domain)), ("code", .int(ns.code)),
      ("description", .string(ns.localizedDescription)),
    ])
  }

  // MARK: Pixels

  /// RGBA8 sRGB pixels of `image` scaled to `width`×`height`.
  public struct Pixels {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init?(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
      let w = width ?? image.width
      let h = height ?? image.height
      guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
      var buffer = [UInt8](repeating: 0, count: w * h * 4)
      let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard
          let context = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
      }
      guard drawn else { return nil }
      self.width = w
      self.height = h
      bytes = buffer
    }

    public func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
      let i = (y * width + x) * 4
      return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
  }

  /// Mean luminance (0-255), its spread, the share of near-black pixels and how many distinct
  /// coarse colors a 64×40 thumbnail has. A blank or redacted frame has a tiny spread and few
  /// colors.
  public static func stats(_ image: CGImage) -> JSON {
    guard let pixels = Pixels(image, width: 64, height: 40) else { return .null }
    var sum = 0.0
    var sumSquares = 0.0
    var black = 0
    var colors = Set<Int>()
    for y in 0..<pixels.height {
      for x in 0..<pixels.width {
        let (r, g, b) = pixels.rgb(x, y)
        let luminance = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        sum += luminance
        sumSquares += luminance * luminance
        if r < 8, g < 8, b < 8 { black += 1 }
        colors.insert((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4))
      }
    }
    let count = Double(pixels.width * pixels.height)
    let mean = sum / count
    return .obj([
      ("width", .int(image.width)), ("height", .int(image.height)),
      ("mean_luminance", .double((mean * 10).rounded() / 10)),
      (
        "luminance_stddev",
        .double((max(0, sumSquares / count - mean * mean).squareRoot() * 10).rounded() / 10)
      ),
      ("near_black_fraction", .double((Double(black) / count * 1000).rounded() / 1000)),
      ("coarse_colors", .int(colors.count)),
    ])
  }

  /// How different two images are, on a 64×40 grid: mean absolute channel difference and the
  /// share of cells that differ by more than 24 in any channel.
  public static func difference(_ a: CGImage, _ b: CGImage) -> JSON {
    guard let pa = Pixels(a, width: 64, height: 40), let pb = Pixels(b, width: 64, height: 40)
    else { return .null }
    var total = 0.0
    var changed = 0
    for y in 0..<40 {
      for x in 0..<64 {
        let (r1, g1, b1) = pa.rgb(x, y)
        let (r2, g2, b2) = pb.rgb(x, y)
        let d = [abs(r1 - r2), abs(g1 - g2), abs(b1 - b2)]
        total += Double(d.reduce(0, +)) / 3
        if d.max()! > 24 { changed += 1 }
      }
    }
    return .obj([
      ("mean_abs_diff", .double((total / 2560 * 10).rounded() / 10)),
      ("changed_cell_fraction", .double((Double(changed) / 2560 * 1000).rounded() / 1000)),
    ])
  }

  /// Share of pixels in `rect` (image pixel coordinates, top-left origin) within `tolerance` of
  /// `color` in every channel.
  public static func colorFraction(
    _ image: CGImage, in rect: CGRect, color: (Int, Int, Int), tolerance: Int = 40
  ) -> Double? {
    let bounded = rect.integral.intersection(
      CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !bounded.isEmpty, let crop = image.cropping(to: bounded) else { return nil }
    let w = min(crop.width, 64)
    let h = min(crop.height, 64)
    guard let pixels = Pixels(crop, width: w, height: h) else { return nil }
    var hits = 0
    for y in 0..<h {
      for x in 0..<w {
        let (r, g, b) = pixels.rgb(x, y)
        if abs(r - color.0) <= tolerance, abs(g - color.1) <= tolerance,
          abs(b - color.2) <= tolerance
        {
          hits += 1
        }
      }
    }
    return Double(hits) / Double(w * h)
  }

  /// Centroid (image pixels) of the pixels within `tolerance` of `color` inside `search`.
  public static func centroid(
    _ image: CGImage, of color: (Int, Int, Int), in search: CGRect, tolerance: Int = 40
  ) -> (point: CGPoint, count: Int)? {
    let bounded = search.integral.intersection(
      CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !bounded.isEmpty, let crop = image.cropping(to: bounded),
      let pixels = Pixels(crop)
    else { return nil }
    var sx = 0.0
    var sy = 0.0
    var n = 0
    for y in 0..<pixels.height {
      for x in 0..<pixels.width {
        let (r, g, b) = pixels.rgb(x, y)
        if abs(r - color.0) <= tolerance, abs(g - color.1) <= tolerance,
          abs(b - color.2) <= tolerance
        {
          sx += Double(x) + 0.5
          sy += Double(y) + 0.5
          n += 1
        }
      }
    }
    guard n > 0 else { return nil }
    return (CGPoint(x: bounded.minX + sx / Double(n), y: bounded.minY + sy / Double(n)), n)
  }

  /// Writes a PNG for a person to inspect. Callers only pass directories outside the repository.
  @discardableResult
  public static func savePNG(_ image: CGImage, to url: URL) -> Bool {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
  }

  /// Where images for a person go: `~/Library/Caches/homes.birb.deskhand/spike-captures`.
  public static var imageCacheDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/homes.birb.deskhand/spike-captures")
  }
}
