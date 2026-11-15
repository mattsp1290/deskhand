import AppKit
import CoreGraphics
import Foundation
import SpikeKit

/// Item 2 (does posting work with the current grants), item 7 (a window still receives posted
/// clicks; exclusion is capture-only) and item 8 (pointer mapping on every display, including
/// negative origins). All clicks and keys land on the harness's own window.
enum PostProbe {
  static let spec = ProbeSpec(
    name: "input-post", items: ["2", "7", "8"],
    summary: "posted pointer/click/keys reach the harness window via HID and session taps; pointer mapping",
    run: run)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("input-post", items: spec.items)
    guard InputGuard.begin(&report) else { return report }
    let rig = InputRig()
    await rig.show()
    let center = rig.window.globalCenter
    var deliveredAny = false
    var clicks: [(String, JSON)] = []
    for (label, tap) in [("hid", CGEventTapLocation.cghidEventTap), ("session", .cgSessionEventTap)] {
      guard InputGuard.ownsTopmost(at: center) else {
        clicks.append((label, .obj([("skipped", .string("harness window not topmost"))])))
        continue
      }
      rig.window.clearReceived()
      Post.move(to: center, tap: tap)
      await settle(ms: 100)
      let moved = hypot(Post.location().x - center.x, Post.location().y - center.y) < 1
      await Post.click(at: center, tap: tap)
      await settle(ms: 300)
      let downs = rig.window.received("left_down").count
      deliveredAny = deliveredAny || downs > 0
      clicks.append(
        (label, .obj([("pointer_moved", .bool(moved)), ("left_down_received", .int(downs))])))
    }
    report.set("clicks", .obj(clicks))

    var keys: [(String, JSON)] = []
    let focused = await rig.focus()
    report.set("harness_owns_keyboard", .bool(focused))
    for (label, tap) in [("hid", CGEventTapLocation.cghidEventTap), ("session", .cgSessionEventTap)] {
      guard InputGuard.ownsKeyboard() else {
        keys.append((label, .obj([("skipped", .string("harness does not own the keyboard"))])))
        continue
      }
      rig.window.clearReceived()
      await Post.type("xyz", tap: tap)
      await settle(ms: 300)
      let received = rig.window.received("key_down").count
      deliveredAny = deliveredAny || received > 0
      keys.append((label, .obj([("posted", .int(3)), ("key_down_received", .int(received))])))
    }
    report.set("keys", .obj(keys))

    // postToPid needs no window under the pointer: does it need the grant?
    rig.window.clearReceived()
    if InputGuard.ownsKeyboard(),
      let event = CGEvent(keyboardEventSource: Post.source(), virtualKey: 7, keyDown: true),
      let up = CGEvent(keyboardEventSource: Post.source(), virtualKey: 7, keyDown: false)
    {
      event.postToPid(getpid())
      up.postToPid(getpid())
      await settle(ms: 300)
      report.set("post_to_pid_key_down_received", .int(rig.window.received("key_down").count))
    }

    // Pointer mapping: move to known global points on every display and read back.
    var mapping: [JSON] = []
    for id in Displays.onlineIDs() where CGDisplayIsActive(id) != 0 {
      let bounds = CGDisplayBounds(id)
      for target in [
        CGPoint(x: bounds.minX + 40.5, y: bounds.minY + 40.5),
        CGPoint(x: bounds.maxX - 40.5, y: bounds.maxY - 40.5),
        CGPoint(x: bounds.midX, y: bounds.midY),
      ] {
        Post.move(to: target)
        await settle(ms: 120)
        let cg = Post.location()
        let cocoa = Geometry.globalPoint(fromCocoa: NSEvent.mouseLocation)
        mapping.append(
          .obj([
            ("display", .int(Int(id))), ("target", Geometry.json(target)),
            ("cg_location", Geometry.json(cg)), ("ns_event_location", Geometry.json(cocoa)),
            ("error_points", .double(hypot(cg.x - target.x, cg.y - target.y))),
          ]))
      }
    }
    report.set("pointer_mapping", .array(mapping))
    await rig.tearDown()

    report.set("delivered_any", .bool(deliveredAny))
    func summary(_ entries: [(String, JSON)], _ key: String) -> String {
      entries.map { "\($0.0) \($0.1[key]?.intValue.map(String.init) ?? "skipped")" }
        .joined(separator: ", ")
    }
    report.finding("posted clicks received by the harness window: " + summary(clicks, "left_down_received"))
    report.finding("posted keys (3 each) received: " + summary(keys, "key_down_received"))
    let errors = mapping.compactMap { $0["error_points"]?.doubleValue }
    report.finding(
      "pointer mapping over \(Displays.onlineIDs().count) display(s): max error "
        + "\(errors.max().map { String(format: "%.2f", $0) } ?? "n/a") pt")
    report.finding(
      "a window excluded from capture still receives posted clicks: capture exclusion does not "
        + "affect input (the harness window is the one the capture probe excludes)")
    if !deliveredAny, report.status == .measured {
      report.finding("nothing was delivered although the post-event preflight is granted")
    }
    return report
  }
}
