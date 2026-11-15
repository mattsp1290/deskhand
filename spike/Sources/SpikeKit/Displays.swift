import AppKit
import CoreGraphics
import Foundation

/// Display geometry: global bounds in points (origins can be negative), the current mode's point
/// and pixel sizes, the native pixel size, AppKit's backing scale, and arrangement facts.
public enum Displays {
  /// `kDisplayModeNativeFlag` from IOGraphicsTypes.h.
  private static let nativeFlag: UInt32 = 0x0200_0000

  public static func onlineIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return Array(ids.prefix(Int(count)))
  }

  public static func screen(for id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        == id
    }
  }

  public static func describe(_ id: CGDirectDisplayID) -> JSON {
    let bounds = CGDisplayBounds(id)
    let mode = CGDisplayCopyDisplayMode(id)
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    let native =
      modes.first { $0.ioFlags & nativeFlag != 0 }
      ?? modes.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
    let screen = screen(for: id)
    let pointPixelScale = mode.map { Double($0.pixelWidth) / Double(max(1, $0.width)) }
    let scaled = mode.flatMap { current in
      native.map { $0.pixelWidth != current.pixelWidth || $0.pixelHeight != current.pixelHeight }
    }
    let size = CGDisplayScreenSize(id)
    return .obj([
      ("id", .int(Int(id))),
      ("main", .bool(CGDisplayIsMain(id) != 0)),
      ("builtin", .bool(CGDisplayIsBuiltin(id) != 0)),
      ("active", .bool(CGDisplayIsActive(id) != 0)),
      ("asleep", .bool(CGDisplayIsAsleep(id) != 0)),
      ("in_mirror_set", .bool(CGDisplayIsInMirrorSet(id) != 0)),
      ("mirrors", .int(Int(CGDisplayMirrorsDisplay(id)))),
      ("rotation", .double(CGDisplayRotation(id))),
      ("bounds_points", Geometry.json(bounds)),
      ("negative_origin", .bool(bounds.origin.x < 0 || bounds.origin.y < 0)),
      ("mode_points", .obj([("width", .int(mode?.width)), ("height", .int(mode?.height))])),
      (
        "mode_pixels",
        .obj([("width", .int(mode?.pixelWidth)), ("height", .int(mode?.pixelHeight))])
      ),
      ("point_pixel_scale", .num(pointPixelScale)),
      ("refresh_hz", .num(mode?.refreshRate)),
      (
        "native_pixels",
        .obj([("width", .int(native?.pixelWidth)), ("height", .int(native?.pixelHeight))])
      ),
      ("scaled_from_native", .bool(scaled)),
      ("backing_scale_factor", .num(screen.map { Double($0.backingScaleFactor) })),
      ("ns_screen_frame", screen.map { Geometry.json($0.frame) } ?? .null),
      ("ns_screen_visible_frame", screen.map { Geometry.json($0.visibleFrame) } ?? .null),
      ("name", .str(screen?.localizedName)),
      ("vendor", .int(Int(CGDisplayVendorNumber(id)))),
      ("model", .int(Int(CGDisplayModelNumber(id)))),
      ("physical_mm", .obj([("width", .double(size.width)), ("height", .double(size.height))])),
      ("mode_count", .int(modes.count)),
    ])
  }

  public static func dump() -> JSON {
    .array(onlineIDs().map(describe))
  }

  /// One line per display for findings.
  public static func line(_ display: JSON) -> String {
    let id = display["id"]?.intValue ?? 0
    let b = display["bounds_points"]
    let x = b?["x"]?.doubleValue ?? 0
    let y = b?["y"]?.doubleValue ?? 0
    let w = b?["width"]?.doubleValue ?? 0
    let h = b?["height"]?.doubleValue ?? 0
    var tags: [String] = []
    if display["main"]?.boolValue == true { tags.append("main") }
    if display["builtin"]?.boolValue == true {
      tags.append("built-in")
    } else {
      tags.append("external")
    }
    if display["negative_origin"]?.boolValue == true { tags.append("negative origin") }
    if display["scaled_from_native"]?.boolValue == true { tags.append("scaled") }
    let scale = display["point_pixel_scale"]?.doubleValue ?? 0
    let backing = display["backing_scale_factor"]?.doubleValue ?? 0
    return "display \(id) [\(tags.joined(separator: ", "))]: origin (\(Int(x)), \(Int(y))) "
      + "size \(Int(w))x\(Int(h)) pt, pointPixelScale \(scale), backingScaleFactor \(backing)"
  }
}
