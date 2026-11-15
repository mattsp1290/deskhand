import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit
import SpikeKit

enum CoordinatesProbe {
  static let spec = ProbeSpec(
    name: "coordinates", items: ["8"],
    summary: "marker windows at known global points vs where captures show them, per display",
    run: run)

  static let markerSize: CGFloat = 24
  static let magenta = (255, 0, 255)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("coordinates", items: spec.items)
    report.set("displays_geometry", Displays.dump())
    var markers: [HarnessWindow] = []
    defer { for marker in markers { marker.close() } }
    var planned: [(CGDirectDisplayID, CGPoint)] = []
    for id in Displays.onlineIDs() where CGDisplayIsActive(id) != 0 {
      let bounds = CGDisplayBounds(id)
      let inset: CGFloat = 90
      let centers = [
        CGPoint(x: bounds.minX + inset, y: bounds.minY + inset),
        CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset),
        CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset),
        CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset),
        CGPoint(x: bounds.midX + 0.5, y: bounds.midY + 0.5),
      ]
      for center in centers {
        let rect = CGRect(
          x: center.x - markerSize / 2, y: center.y - markerSize / 2, width: markerSize,
          height: markerSize)
        let marker = HarnessWindow(
          global: rect, color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1), level: .popUpMenu)
        marker.show()
        markers.append(marker)
        planned.append((id, marker.globalCenter))
      }
    }
    await settle(ms: 600)

    let content: SCShareableContent
    do {
      content = try await CaptureTools.shareableContent()
    } catch {
      report.set("shareable_content_error", CaptureTools.errorJSON(error))
      report.block(on: .screenRecording, "SCShareableContent: \(error.localizedDescription)")
      return report
    }
    var results: [JSON] = []
    var worst = 0.0
    for display in content.displays {
      let filter = SCContentFilter(
        display: display, excludingApplications: [], exceptingWindows: [])
      guard let image = try? await CaptureTools.capture(filter) else {
        results.append(
          .obj([("display_id", .int(Int(display.displayID))), ("capture", .string("failed"))]))
        continue
      }
      let info = SCShareableContent.info(for: filter)
      let scale = Double(info.pointPixelScale)
      let measuredScale = Double(image.width) / Double(display.frame.width)
      var found: [JSON] = []
      for (id, center) in planned where id == display.displayID {
        let predicted = CGPoint(
          x: (center.x - display.frame.minX) * scale, y: (center.y - display.frame.minY) * scale)
        let radius = (markerSize + 30) * scale
        let search = CGRect(
          x: predicted.x - radius, y: predicted.y - radius, width: radius * 2, height: radius * 2)
        let hit = CaptureTools.centroid(image, of: magenta, in: search)
        let error = hit.map { hypot($0.point.x - predicted.x, $0.point.y - predicted.y) }
        worst = max(worst, error ?? 9999)
        found.append(
          .obj([
            ("global_center", Geometry.json(center)), ("predicted_px", Geometry.json(predicted)),
            ("found_px", hit.map { Geometry.json($0.point) } ?? .null),
            ("pixel_count", .int(hit?.count)),
            ("expected_pixel_count", .int(Int((markerSize * scale) * (markerSize * scale)))),
            ("error_px", .num(error.map(Double.init))),
          ]))
      }
      results.append(
        .obj([
          ("display_id", .int(Int(display.displayID))), ("frame", Geometry.json(display.frame)),
          ("image_px", .obj([("width", .int(image.width)), ("height", .int(image.height))])),
          ("point_pixel_scale", .double(scale)), ("image_over_frame_scale", .double(measuredScale)),
          ("markers", .array(found)),
        ]))
      let errors = found.compactMap { $0["error_px"]?.doubleValue }
      report.finding(
        "display \(display.displayID): pointPixelScale \(scale), image/frame \(measuredScale), "
          + "markers found \(errors.count)/\(found.count), max error "
          + "\(errors.max().map { String(format: "%.2f", $0) } ?? "n/a") px")
    }
    report.set("displays", .array(results))
    report.set("max_error_px", .double(worst))
    if worst > 2 {
      report.finding("WARNING: a marker was more than 2 px from where the mapping put it")
    }
    return report
  }
}
