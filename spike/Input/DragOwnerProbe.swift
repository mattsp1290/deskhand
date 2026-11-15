import AppKit
import Foundation
import SpikeKit

/// A view that starts a real AppKit drag session on the first mouse-dragged event.
final class DragSourceView: NSView, NSDraggingSource {
  var started = false
  var ended = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.systemPurple.setFill()
    dirtyRect.fill()
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseDragged(with event: NSEvent) {
    guard !started else { return }
    started = true
    let item = NSDraggingItem(pasteboardWriter: "deskhand-spike drag" as NSString)
    item.setDraggingFrame(NSRect(x: 0, y: 0, width: 80, height: 40), contents: nil)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    ended = true
  }
}

/// deskhand-7t13 (b): which process owns the window that carries the drag image. Samples the
/// on-screen windows at the dragging level (and anything under the pointer above normal level)
/// while a drag is in progress.
enum DragOwner {
  static var draggingLevel: Int { Int(CGWindowLevelForKey(.draggingWindow)) }

  /// One sample: windows at or above the dragging level, and the stack at `point`.
  static func sample(at point: CGPoint) -> JSON {
    let windows = WindowList.onScreen()
    let dragLevel = windows.filter { ($0.layer ?? 0) >= draggingLevel - 1 }
    let atPointer = WindowList.stack(at: point, in: windows).prefix(3)
    return .obj([
      ("t", Clock.stamp()), ("pointer", Geometry.json(point)),
      ("drag_level_windows", .array(dragLevel.map(\.json))),
      ("stack_at_pointer", .array(atPointer.map(\.json))),
    ])
  }

  /// Distinct owners of drag-level windows across samples, with their code signatures.
  static func owners(_ samples: [JSON]) -> JSON {
    var seen: [Int: JSON] = [:]
    for sample in samples {
      for window in sample["drag_level_windows"]?.arrayValue ?? [] {
        guard let pid = window["owner_pid"]?.intValue, seen[pid] == nil else { continue }
        let facts = CodeSigning.facts(pid: pid_t(pid))
        seen[pid] = .obj([
          ("owner_name", window["owner_name"].orNull), ("layer", window["layer"].orNull),
          ("identifier", facts["identifier"].orNull), ("bundle_id", facts["bundle_id"].orNull),
          ("team_id", facts["team_id"].orNull),
          ("anchor_apple", (facts["requirements"]?["anchor_apple"]).orNull),
        ])
      }
    }
    return .array(seen.keys.sorted().compactMap { seen[$0] })
  }
}

enum DragOwnerProbe {
  static let spec = ProbeSpec(
    name: "input-drag-owner", items: ["7t13-b"],
    summary: "owner of the drag-image window during a posted AppKit drag",
    run: run)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("input-drag-owner", items: spec.items)
    guard InputGuard.begin(&report) else { return report }
    guard CGPreflightPostEventAccess() else { return report }
    let main = CGDisplayBounds(CGMainDisplayID())
    let source = HarnessWindow(
      global: CGRect(x: main.midX - 300, y: main.midY - 60, width: 160, height: 120),
      color: .systemPurple, level: .popUpMenu)
    let dragView = DragSourceView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
    source.contentView = dragView
    let target = HarnessWindow(
      global: CGRect(x: main.midX + 100, y: main.midY - 60, width: 200, height: 120),
      color: .systemGray, level: .popUpMenu)
    source.show()
    target.show()
    await settle(ms: 400)
    let start = source.globalCenter
    let end = target.globalCenter
    guard InputGuard.ownsTopmost(at: start) else {
      report.skip("harness drag source is not the topmost window")
      source.close()
      target.close()
      return report
    }
    report.set("baseline", DragOwner.sample(at: start))
    Post.move(to: start)
    Post.mouse(.leftMouseDown, at: start)
    await Clock.sleep(ms: 100)
    var samples: [JSON] = []
    let steps = 40
    for step in 1...steps {
      let t = CGFloat(step) / CGFloat(steps)
      let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
      Post.mouse(.leftMouseDragged, at: point)
      await Clock.sleep(ms: 25)
      if step % 5 == 0 { samples.append(DragOwner.sample(at: point)) }
    }
    Post.mouse(.leftMouseUp, at: end)
    await settle(ms: 500)
    source.close()
    target.close()
    report.set("drag_started", .bool(dragView.started))
    report.set("drag_ended", .bool(dragView.ended))
    report.set("samples", .array(samples))
    let owners = DragOwner.owners(samples)
    report.set("drag_level_owners", owners)
    let names = (owners.arrayValue ?? []).map {
      "\($0["owner_name"]?.stringValue ?? "?") (id \($0["identifier"]?.stringValue ?? "?"), "
        + "bundle \($0["bundle_id"]?.stringValue ?? "none"), layer \($0["layer"]?.intValue ?? 0))"
    }
    report.finding(
      "posted drag started an AppKit session: \(dragView.started); drag-level window owners: "
        + (names.isEmpty ? "none seen" : names.joined(separator: "; ")))
    report.needsHuman = true
    report.note("a real Finder drag by a person: trial drag-owner")
    return report
  }
}
