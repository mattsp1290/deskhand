import AppKit
import CoreGraphics
import Foundation
import SpikeKit

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
        await Clock.sleep(ms: 1300)
        let before = Signals.idle()
        let started = Clock.monoMs()
        rig.window.clearReceived()
        let click =
          InputGuard.ownsTopmost(at: center)
          ? await Post.click(at: center, tap: tap, state: state)
          : ClickReceipt(down: nil, up: nil)
        Post.move(to: CGPoint(x: center.x + 1, y: center.y), tap: tap, state: state)
        Post.move(to: center, tap: tap, state: state)
        await settle(ms: 200)
        let after = Signals.idle()
        let observed = Clock.monoMs()
        let delivery = click.delivery(
          in: rig.window.received, startedMs: started, endedMs: observed)
        let delivered = delivery.qualified
        var resets: [(String, JSON)] = []
        for key in ["hid_any_s", "combined_any_s", "iohid_idle_s"] {
          let assessment = MeasurementAnalysis.idle(
            delivered: delivered,
            before: before[key]?.doubleValue, after: after[key]?.doubleValue,
            elapsed: (observed - started) / 1000)
          resets.append((key, assessment.json))
        }
        if resets.first(where: { $0.0 == "hid_any_s" })?.1 == .string("unchanged") {
          personOnlyCandidates.append("\(stateName)+\(tapName)")
        }
        matrix.append(
          .obj([
            ("source_state", .string(stateName)), ("tap", .string(tapName)),
            ("click_posted", .bool(click.allPosted)), ("click_delivered", .bool(delivered)),
            ("click_receipt", click.json), ("delivery", delivery.json),
            ("received_events", .array(rig.window.received.map(\.json))),
            ("action_started_ms", .double(started)), ("observed_ms", .double(observed)),
            ("before", before), ("after", after), ("reset", .obj(resets)),
          ]))
      }
    }
    report.set("matrix", .array(matrix))
    for row in matrix {
      let reset = row["reset"]?.members?.filter { $0.value == .string("reset") }.map(\.key) ?? []
      report.finding(
        "source \(row["source_state"]?.stringValue ?? "?") via \(row["tap"]?.stringValue ?? "?") tap: "
          + "delivered \(row["click_delivered"]?.boolValue == true), resets "
          + (reset.isEmpty ? "nothing" : reset.joined(separator: ", ")))
    }
    report.set("unchanged_hid_source_tap_pairs", .strings(personOnlyCandidates))
    let validHID = matrix.filter {
      ["reset", "unchanged"].contains($0["reset"]?["hid_any_s"]?.stringValue ?? "")
    }
    if validHID.isEmpty { report.status = .inconclusive }
    report.finding(
      validHID.isEmpty
        ? "HID source classification is inconclusive; no valid delivered trials."
        : "Valid HID rows \(validHID.count)/\(matrix.count); unchanged for delivered source/tap pairs: \(personOnlyCandidates). This tests own posts only; physical-person discrimination remains unqualified."
    )

    var offsets: [String: [Double]] = [:]
    var echoRows: [JSON] = []
    for _ in 0..<25 {
      await Clock.sleep(ms: 1300)
      let before = Signals.idle()
      rig.window.clearReceived()
      let started = Clock.monoMs()
      let click =
        InputGuard.ownsTopmost(at: center)
        ? await Post.click(at: center, tap: .cghidEventTap, state: .hidSystemState)
        : ClickReceipt(down: nil, up: nil)
      await Clock.sleep(ms: 60)
      let read = Clock.monoMs()
      let after = Signals.idle()
      let delivery = click.delivery(in: rig.window.received, startedMs: started, endedMs: read)
      let delivered = delivery.qualified
      for key in ["hid_any_s", "combined_any_s", "iohid_idle_s"] {
        var assessment = MeasurementAnalysis.idle(
          delivered: delivered, before: before[key]?.doubleValue,
          after: after[key]?.doubleValue, elapsed: (read - started) / 1000)
        let offset = MeasurementAnalysis.echoOffset(
          observedMs: read, idleSeconds: after[key]?.doubleValue,
          postedMs: click.up?.monotonicMs)
        if assessment == .reset, !(offset.map { $0 >= 0 } ?? false) {
          assessment = .inconclusive("idle-implied event does not match the posted mouse-up")
        }
        if assessment == .reset, let offset { offsets[key, default: []].append(offset) }
        echoRows.append(
          .obj([
            ("counter", .string(key)), ("source", .string("hid_system")),
            ("tap", .string("hid")), ("before", before[key].orNull), ("after", after[key].orNull),
            ("action_started_ms", .double(started)),
            ("down_posted_ms", .num(click.down?.monotonicMs)),
            ("up_posted_ms", .num(click.up?.monotonicMs)),
            ("all_posted", .bool(click.allPosted)),
            ("click_receipt", click.json), ("delivery", delivery.json),
            ("received_events", .array(rig.window.received.map(\.json))),
            ("observed_ms", .double(read)),
            ("implied_event_ms", .num(after[key]?.doubleValue.map { read - $0 * 1000 })),
            ("assessment", assessment.json), ("raw_offset_ms", .num(offset)),
          ]))
      }
    }
    report.set("echo_observations", .array(echoRows))
    if offsets.isEmpty {
      report.status = .inconclusive
      report.note("No valid observed counter resets; echo tolerance remains unmeasured.")
    }
    report.set(
      "echo_offset_ms",
      .obj(offsets.sorted { $0.key < $1.key }.map { ($0.key, percentiles($0.value)) }))
    for (key, values) in offsets.sorted(by: { $0.key < $1.key }) {
      let stats = percentiles(values)
      report.finding(
        "\(key): last-event time implied by the idle counter minus post time: p50 "
          + "\(milliseconds(stats["p50"])) ms, p95 \(milliseconds(stats["p95"])) ms, max "
          + "\(milliseconds(stats["max"])) ms (a 50 ms tolerance must cover the max)")
    }
    await rig.tearDown()
    return report
  }

  static func milliseconds(_ value: JSON?) -> String {
    guard let number = value?.doubleValue, number.isFinite else { return "unavailable" }
    return String(format: "%.1f", number)
  }
}
