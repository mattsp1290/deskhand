import AppKit
import ApplicationServices
import Foundation
import SpikeKit

enum ClickThroughProbe {
  static let spec = ProbeSpec(
    name: "input-click-through", items: ["7t13-d"],
    summary: "click-through overlay: window-list topmost vs event hit test vs posted click",
    run: run)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("input-click-through", items: spec.items)
    guard InputGuard.begin(&report) else { return report }
    let main = CGDisplayBounds(CGMainDisplayID())
    let below = HarnessWindow(
      global: CGRect(x: main.midX - 150, y: main.midY - 100, width: 300, height: 200),
      color: .systemBlue, level: .popUpMenu)
    let overlay = HarnessWindow(
      global: CGRect(x: main.midX - 170, y: main.midY - 120, width: 340, height: 240),
      color: NSColor.systemRed.withAlphaComponent(0.4),
      level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1))
    overlay.isOpaque = false
    overlay.ignoresMouseEvents = true
    below.show()
    overlay.show()
    await settle(ms: 500)
    let point = below.globalCenter

    let stack = WindowList.stack(at: point)
    let listTop = stack.first?.number
    let eventTarget = WindowList.eventTargetWindowNumber(at: point)
    report.set("window_list_stack", .array(stack.prefix(4).map(\.json)))
    report.set("overlay_window", .int(overlay.windowNumber))
    report.set("below_window", .int(below.windowNumber))
    report.set("window_list_topmost", .int(listTop))
    report.set("ns_window_number_at_point", .int(eventTarget))
    report.set("ax_hit_test", axHit(point))

    var clickTo = "not posted"
    if stack.first?.ownerPID == getpid() {
      below.clearReceived()
      overlay.clearReceived()
      _ = await Post.click(at: point)
      await settle(ms: 300)
      let belowGot = below.received("left_down").count
      let overlayGot = overlay.received("left_down").count
      clickTo = belowGot > 0 ? "below" : overlayGot > 0 ? "overlay" : "neither"
      report.set(
        "posted_click",
        .obj([("below_received", .int(belowGot)), ("overlay_received", .int(overlayGot))]))
    }
    overlay.close()
    below.close()
    func name(_ number: Int?) -> String {
      number == overlay.windowNumber
        ? "overlay" : number == below.windowNumber ? "below" : "\(number ?? 0)"
    }
    report.finding(
      "click-through overlay: CGWindowList topmost = \(name(listTop)), NSWindow.windowNumber(at:) = "
        + "\(name(eventTarget)), posted click reached \(clickTo)")
    report.finding(
      "window-list entries carry no 'ignores mouse events' flag; compare alpha/sharing in evidence")
    return report
  }

  static func axHit(_ point: CGPoint) -> JSON {
    guard AXIsProcessTrusted() else { return .obj([("error", .string("accessibility_untrusted"))]) }
    var element: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(
      AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
    guard error == .success, let element else {
      return .obj([("error", .string("AXError \(error.rawValue)"))])
    }
    var pid: pid_t = 0
    _ = AXUIElementGetPid(element, &pid)
    var role: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    var frame: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frame)
    var rect = CGRect.zero
    if let frame, CFGetTypeID(frame) == AXValueGetTypeID() {
      AXValueGetValue(unsafeDowncast(frame, to: AXValue.self), .cgRect, &rect)
    }
    return .obj([
      ("pid", .int(Int(pid))), ("role", .str(role as? String)), ("frame", Geometry.json(rect)),
    ])
  }
}
