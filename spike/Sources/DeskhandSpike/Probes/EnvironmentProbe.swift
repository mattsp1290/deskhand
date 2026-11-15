import AppKit
import Foundation
import SpikeKit

/// Item 1 (macOS version) and item 8 (display geometry dump).
enum EnvironmentProbe {
  static let spec = ProbeSpec(
    name: "environment", items: ["1", "8"],
    summary: "macOS version, hardware, display geometry (scales, native vs scaled, negative origins)",
    run: run)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("environment", items: spec.items)
    let version = ProcessInfo.processInfo.operatingSystemVersion
    report.set(
      "macos",
      .obj([
        ("version", .string(Host.macOSVersion)),
        ("major", .int(version.majorVersion)), ("minor", .int(version.minorVersion)),
        ("patch", .int(version.patchVersion)),
        ("version_string", .string(ProcessInfo.processInfo.operatingSystemVersionString)),
      ]))
    report.set(
      "hardware",
      .obj([
        ("model", .str(Host.sysctlString("hw.model"))),
        ("cpu", .str(Host.sysctlString("machdep.cpu.brand_string"))),
        ("memory_bytes", .int(Host.sysctlInt("hw.memsize"))),
        ("arch", .str(Host.sysctlString("hw.machine"))),
      ]))
    report.set("host_name", .string(ProcessInfo.processInfo.hostName))
    report.set("mac_name", .string(Host.macName))
    report.set("uptime_s", .double(ProcessInfo.processInfo.systemUptime.rounded()))
    report.set("console_user", Signals.consoleUser())
    let displays = Displays.dump()
    report.set("displays", displays)
    let union = Displays.onlineIDs().map(CGDisplayBounds).reduce(CGRect.null) { $0.union($1) }
    report.set("desktop_union_points", Geometry.json(union))
    report.set("ns_screens", .int(NSScreen.screens.count))

    report.finding("macOS \(Host.macOSVersion) on \(Host.sysctlString("hw.model") ?? "?")")
    for display in displays.arrayValue ?? [] { report.finding(Displays.line(display)) }
    let all = displays.arrayValue ?? []
    if !all.contains(where: { $0["builtin"]?.boolValue == false }) {
      report.note("no external display attached: item 8 needs the coordinates trial with one")
    }
    if !all.contains(where: { $0["negative_origin"]?.boolValue == true }) {
      report.note("no display has a negative origin: arrange one left of the main display")
    }
    return report
  }
}
