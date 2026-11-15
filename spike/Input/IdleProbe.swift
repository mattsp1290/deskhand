import AppKit
import CoreGraphics
import Foundation
import SpikeKit

/// deskhand-7t13 (a) and (g): which idle counters the harness's own posts reset, for every
/// event-source state and tap, and how far the idle signal's implied "last event" time lands
/// from the post (the echo the 50 ms tolerance must cover).
enum IdleProbe {
  static let spec = ProbeSpec(
    name: "input-idle", items: ["7t13-a", "7t13-echo"],
    summary: "own posts vs HID/combined/IOHID idle counters per source and tap; echo latency",
    run: run)

  static let states: [(String, CGEventSourceStateID)] = [
    ("hid_system", .hidSystemState), ("combined_session", .combinedSessionState),
    ("private", .privateState),
  ]
  static let taps: [(String, CGEventTapLocation)] = [
    ("hid", .cghidEventTap), ("session", .cgSessionEventTap),
  ]

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("input-idle", items: spec.items)
    guard InputGuard.begin(&report) else { return report }
    guard CGPreflightPostEventAccess() else { return report }
    // The counters only say something when the person is not using the Mac.
    var waited = 0
    while CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Signals.anyInputEvent)
      < 2, waited < 30
    {
      await Clock.sleep(ms: 500)
      waited += 1
    }
    let personIdle = CGEventSource.secondsSinceLastEventType(
      .hidSystemState, eventType: Signals.anyInputEvent)
    report.set("person_idle_at_start_s", .double(personIdle))
    if personIdle < 2 {
      report.note("the person kept using the Mac; results are inconclusive. Rerun hands-off.")
    }

    let rig = InputRig()
    await rig.show()
    let center = rig.window.globalCenter
    var matrix: [JSON] = []
    var personOnlyCandidates: [String] = []
    for (stateName, state) in states {
      for (tapName, tap) in taps {
        // Let every counter pass 1.2 s so a reset is visible.
        await Clock.sleep(ms: 1300)
        let before = Signals.idle()
        rig.window.clearReceived()
        var clicked = false
        if InputGuard.ownsTopmost(at: center) {
          clicked = await Post.click(at: center, tap: tap, state: state)
        }
        Post.move(to: CGPoint(x: center.x + 1, y: center.y), tap: tap, state: state)
        Post.move(to: center, tap: tap, state: state)
        await settle(ms: 200)
        let after = Signals.idle()
        let delivered = rig.window.received("left_down").count > 0
        var resets: [(String, JSON)] = []
        for key in ["hid_any_s", "combined_any_s", "iohid_idle_s"] {
          let b = before[key]?.doubleValue ?? 0
          let a = after[key]?.doubleValue ?? 0
          resets.append((key, .bool(b >= 1 && a < 0.6)))
        }
        let resetsHID = resets.first { $0.0 == "hid_any_s" }?.1.boolValue == true
        if delivered, !resetsHID { personOnlyCandidates.append("\(stateName)+\(tapName)") }
        matrix.append(
          .obj([
            ("source_state", .string(stateName)), ("tap", .string(tapName)),
            ("click_posted", .bool(clicked)), ("click_delivered", .bool(delivered)),
            ("before", before), ("after", after), ("reset", .obj(resets)),
          ]))
      }
    }
    report.set("matrix", .array(matrix))
    for row in matrix {
      let reset = row["reset"]?.members?.filter { $0.value.boolValue == true }.map(\.key) ?? []
      report.finding(
        "source \(row["source_state"]?.stringValue ?? "?") via \(row["tap"]?.stringValue ?? "?") tap: "
          + "delivered \(row["click_delivered"]?.boolValue == true), resets "
          + (reset.isEmpty ? "nothing" : reset.joined(separator: ", ")))
    }
    report.set("person_only_candidates", .strings(personOnlyCandidates))
    report.finding(
      personOnlyCandidates.isEmpty
        ? "no source/tap delivers events without resetting the HID idle counter: the HID signal is any-origin"
        : "HID idle stays person-only for posts via: \(personOnlyCandidates.joined(separator: ", "))")

    // Echo: how far after the post the idle signal places the last event.
    var offsets: [String: [Double]] = [:]
    for _ in 0..<25 {
      await Clock.sleep(ms: 400)
      let posted = Clock.monoMs()
      Post.move(to: CGPoint(x: center.x + 1, y: center.y))
      Post.move(to: center)
      await Clock.sleep(ms: 60)
      let read = Clock.monoMs()
      for (key, state) in [("hid_any", CGEventSourceStateID.hidSystemState), ("combined_any", .combinedSessionState)] {
        let idle = CGEventSource.secondsSinceLastEventType(state, eventType: Signals.anyInputEvent)
        offsets[key, default: []].append(((read - idle * 1000) - posted).rounded())
      }
      if let iohid = Signals.hidIdleSeconds() {
        offsets["iohid", default: []].append(((read - iohid * 1000) - posted).rounded())
      }
    }
    report.set("echo_offset_ms", .obj(offsets.sorted { $0.key < $1.key }.map { ($0.key, percentiles($0.value)) }))
    for (key, values) in offsets.sorted(by: { $0.key < $1.key }) {
      let stats = percentiles(values)
      report.finding(
        "\(key): last-event time implied by the idle counter minus post time: p50 "
          + "\(stats["p50"]?.intValue ?? 0) ms, p95 \(stats["p95"]?.intValue ?? 0) ms, max "
          + "\(stats["max"]?.intValue ?? 0) ms (a 50 ms tolerance must cover the max)")
    }
    await rig.tearDown()
    return report
  }
}
