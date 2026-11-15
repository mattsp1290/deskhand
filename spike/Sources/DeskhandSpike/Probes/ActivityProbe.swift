import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import SpikeKit

/// Item 5 (automatic part) and deskhand-7t13 (a): the HID idle counters, and whether
/// `IOPMAssertionDeclareUserActivity` resets them. The effect on a sleeping display is the wake
/// trial, because it needs the display asleep and a person to unlock afterwards.
enum ActivityProbe {
  static let spec = ProbeSpec(
    name: "activity", items: ["5", "7t13-a"],
    summary: "HID idle counters; does IOPMAssertionDeclareUserActivity reset them",
    run: run)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("activity", items: spec.items)
    let before = Signals.idle()
    report.set("idle_before", before)
    report.set("displays", Signals.displaysAsleep())
    guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
      report.skip("main display is asleep; declaring activity would wake it (trial wake covers this)")
      return report
    }
    let hidBefore = before["hid_any_s"]?.doubleValue ?? 0
    if hidBefore < 2 {
      report.note("person active within 2 s before the probe: the reset reading is inconclusive")
    }
    var assertion: IOPMAssertionID = 0
    let status = IOPMAssertionDeclareUserActivity(
      "deskhand-spike activity probe" as CFString, kIOPMUserActiveLocal, &assertion)
    await settle(ms: 400)
    let after = Signals.idle()
    if assertion != 0 { IOPMAssertionRelease(assertion) }
    report.set("declare_user_activity_status", .int(Int(status)))
    report.set("idle_after", after)
    var resets: [(String, JSON)] = []
    for key in ["hid_any_s", "combined_any_s", "iohid_idle_s"] {
      let b = before[key]?.doubleValue ?? 0
      let a = after[key]?.doubleValue ?? 0
      resets.append((key, .bool(b > 1 && a < 0.5)))
    }
    report.set("reset_by_assertion", .obj(resets))
    let summary = resets.map { "\($0.0) \($0.1.boolValue == true ? "reset" : "not reset")" }
    report.finding(
      "IOPMAssertionDeclareUserActivity (status \(status)): " + summary.joined(separator: ", "))
    report.note("effect on a sleeping display and on the lock screen: trial wake")
    return report
  }
}
