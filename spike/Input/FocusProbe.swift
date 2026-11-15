import AppKit
import Foundation
import SpikeKit

enum FocusProbe {
  static let spec = ProbeSpec(
    name: "input-focus", items: ["7t13-e"],
    summary: "AX focused application vs frontmost app, incl. a non-activating panel",
    run: run)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("input-focus", items: spec.items)
    guard InputGuard.begin(&report) else { return report }
    report.set("baseline", Focus.json())
    if !AXIsProcessTrusted() { report.block(on: .accessibility, "AXIsProcessTrusted is false") }
    let rig = InputRig()
    await rig.show()
    let active = await rig.focus()
    report.set("harness_active", .obj([("owns_keyboard", .bool(active)), ("focus", Focus.json())]))

    var panelResult: [(String, JSON)] = []
    if let finder = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.apple.finder"
    ).first {
      finder.activate()
      await settle(ms: 600)
      let main = CGDisplayBounds(CGMainDisplayID())
      let panel = NSPanel(
        contentRect: Geometry.cocoaRect(
          fromGlobal: CGRect(x: main.midX - 150, y: main.midY + 150, width: 300, height: 120)),
        styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.level = .popUpMenu
      let view = RecordingView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
      view.color = .systemOrange
      var received = 0
      view.onEvent = { event in if event.kind == "key_down" { received += 1 } }
      panel.contentView = view
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(view)
      await settle(ms: 500)
      let focus = Focus.json()
      panelResult.append(("focus_with_panel_key", focus))
      panelResult.append(("panel_is_key", .bool(panel.isKeyWindow)))
      let axSaysHarness = focus["ax_focused_pid"]?.intValue == Int(getpid())
      if axSaysHarness || (!AXIsProcessTrusted() && panel.isKeyWindow) {
        await Post.type("xyz")
        await settle(ms: 300)
        panelResult.append(("posted_keys", .int(3)))
        panelResult.append(("panel_received", .int(received)))
      } else {
        panelResult.append(("posted_keys", .string("skipped: focus not confirmed on the panel")))
      }
      panel.close()
    } else {
      panelResult.append(("skipped", .string("Finder not running")))
    }
    report.set("non_activating_panel", .obj(panelResult))
    await rig.tearDown()

    let activeFocus = report.evidence.first { $0.0 == "harness_active" }?.1["focus"]
    report.finding(
      "harness active: AX focused app = harness \(activeFocus?["ax_focused_pid"]?.intValue == Int(getpid())), "
        + "frontmost = harness \(activeFocus?["frontmost_pid"]?.intValue == Int(getpid()))")
    let panelFocus = panelResult.first { $0.0 == "focus_with_panel_key" }?.1
    if let panelFocus {
      report.finding(
        "non-activating panel key: frontmost \(panelFocus["frontmost_bundle_id"]?.stringValue ?? "?"), "
          + "AX focused app \(panelFocus["ax_focused_bundle_id"]?.stringValue ?? panelFocus["ax_error"]?.stringValue ?? "?"), "
          + "posted keys received by the panel: "
          + "\(panelResult.first { $0.0 == "panel_received" }?.1.intValue.map(String.init) ?? "not posted")"
      )
    }
    return report
  }
}
