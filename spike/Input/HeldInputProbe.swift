import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SpikeKit

/// "Held synthetic input after process exit": a child process posts a key-down, a modifier
/// down or a mouse-button down over the harness window and exits; the parent reads the key,
/// flag and button state afterwards, then releases what is still held.
enum HeldInputProbe {
  static let spec = ProbeSpec(
    name: "input-held", items: ["held-input"],
    summary: "does input held by a posting process stay held after it exits",
    run: run)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("input-held", items: spec.items)
    guard InputGuard.begin(&report) else { return report }
    guard CGPreflightPostEventAccess() else { return report }
    let rig = InputRig()
    await rig.show()
    guard await rig.focus() else {
      report.skip("the harness could not own the keyboard")
      await rig.tearDown()
      return report
    }
    let center = rig.window.globalCenter
    var cases: [(String, JSON)] = []
    for kind in ["key", "shift", "mouse"] {
      if kind == "mouse", !InputGuard.ownsTopmost(at: center) {
        cases.append((kind, .obj([("skipped", .string("harness window not topmost"))])))
        continue
      }
      if kind != "mouse", !InputGuard.ownsKeyboard() {
        cases.append((kind, .obj([("skipped", .string("harness does not own the keyboard"))])))
        continue
      }
      rig.window.clearReceived()
      let child = await runChild(["hold", kind, "\(center.x)", "\(center.y)"])
      var readings: [JSON] = []
      var elapsed = 0
      for delay in [0, 200, 1000, 3000] {
        await Clock.sleep(ms: delay - elapsed)
        elapsed = delay
        readings.append(.obj([("ms_after_exit", .int(delay)), ("state", state(kind))]))
      }
      let received = rig.window.received.map(\.kind)
      release(kind, at: center)
      await settle(ms: 200)
      cases.append(
        (
          kind,
          .obj([
            ("child", child), ("readings", .array(readings)),
            ("events_received_while_held", .strings(received)),
            ("after_release", state(kind)),
          ])
        ))
    }
    await rig.tearDown()
    report.set("cases", .obj(cases))
    for (kind, value) in cases {
      let readings = value["readings"]?.arrayValue ?? []
      let held = readings.map { reading -> String in
        let state = reading["state"]
        let down = state?["hid"]?.boolValue == true || state?["combined"]?.boolValue == true
        return "\(reading["ms_after_exit"]?.intValue ?? 0) ms \(down ? "HELD" : "released")"
      }
      report.finding("\(kind) posted down by a child that exited: " + held.joined(separator: ", "))
    }
    return report
  }

  static func state(_ kind: String) -> JSON {
    switch kind {
    case "key":
      return .obj([
        ("hid", .bool(CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_ANSI_X)))),
        (
          "combined",
          .bool(CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_X)))
        ),
      ])
    case "shift":
      return .obj([
        ("hid", .bool(CGEventSource.flagsState(.hidSystemState).contains(.maskShift))),
        ("combined", .bool(CGEventSource.flagsState(.combinedSessionState).contains(.maskShift))),
      ])
    default:
      return .obj([
        ("hid", .bool(CGEventSource.buttonState(.hidSystemState, button: .left))),
        ("combined", .bool(CGEventSource.buttonState(.combinedSessionState, button: .left))),
      ])
    }
  }

  static func release(_ kind: String, at point: CGPoint) {
    switch kind {
    case "key": Post.key(kVK_ANSI_X, down: false)
    case "shift": Post.key(kVK_Shift, down: false)
    default: Post.mouse(.leftMouseUp, at: point)
    }
  }

  /// Runs this executable as the child (same bundle, same TCC responsibility).
  static func runChild(_ arguments: [String]) async -> JSON {
    let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let started = Clock.monoMs()
    let result = await Shell.runAsync(path, [InputCatalog.childCommand] + arguments, timeout: 10)
    return .obj([
      ("status", .int(Int(result.status))), ("output", .string(result.stdout)),
      ("ms", .int(Int(Clock.monoMs() - started))),
    ])
  }

  /// The child side: post one "down" event and exit without releasing it.
  static func child(_ arguments: [String]) async -> Int32 {
    guard arguments.first == "hold", arguments.count >= 2 else { return 2 }
    let x = Double(arguments.count > 2 ? arguments[2] : "") ?? 0
    let y = Double(arguments.count > 3 ? arguments[3] : "") ?? 0
    switch arguments[1] {
    case "key": Post.key(kVK_ANSI_X, down: true)
    case "shift": Post.key(kVK_Shift, down: true, flags: .maskShift)
    case "mouse": Post.mouse(.leftMouseDown, at: CGPoint(x: x, y: y))
    default: return 2
    }
    print("posted \(arguments[1]) down; exiting without release")
    fflush(stdout)
    return 0
  }
}
