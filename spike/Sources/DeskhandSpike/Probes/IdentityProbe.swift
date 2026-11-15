import AppKit
import CoreGraphics
import Foundation
import SpikeKit

/// deskhand-7t13 (c) Mac App Store apps vs the team anchor requirement, Apple platform binaries
/// (no team identifier), and contract item 73: which process owns the menu bar, the status
/// items, the Dock and the desktop, and whether each has a bundle identifier. Also the
/// harness's own signature, which TCC grants are bound to (item 3).
enum IdentityProbe {
  static let spec = ProbeSpec(
    name: "identity", items: ["3", "7t13-c", "7t13-apple-team", "contract-73"],
    summary: "code-signing facts of the harness, system UI owners and running apps",
    run: run)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("identity", items: spec.items)
    let me = CodeSigning.selfFacts()
    report.set("self", me)
    report.finding(
      "harness signature: team \(me["team_id"]?.stringValue ?? "none"), adhoc "
        + "\(me["adhoc"]?.boolValue == true), hardened runtime \(me["hardened_runtime"]?.boolValue == true), "
        + "designated requirement: \(me["designated_requirement"]?.stringValue ?? "none")")

    // Owners of the system UI, by the topmost window at characteristic points.
    let windows = WindowList.onScreen()
    let main = CGDisplayBounds(CGMainDisplayID())
    let points: [(String, CGPoint)] = [
      ("menu_bar_title_area", CGPoint(x: main.minX + 300, y: main.minY + 5)),
      ("menu_bar_status_area", CGPoint(x: main.maxX - 120, y: main.minY + 5)),
      ("dock_bottom_center", CGPoint(x: main.midX, y: main.maxY - 4)),
    ]
    var owners: [(String, JSON)] = []
    var measured: [pid_t: JSON] = [:]
    func facts(_ pid: pid_t) -> JSON {
      if let known = measured[pid] { return known }
      let value = CodeSigning.facts(pid: pid)
      measured[pid] = value
      return value
    }
    for (label, point) in points {
      let stack = WindowList.stack(at: point, in: windows)
      guard let top = stack.first else {
        owners.append((label, .obj([("window", .null)])))
        report.finding("\(label): no window at \(Int(point.x)),\(Int(point.y))")
        continue
      }
      let signature = top.ownerPID.map(facts).orNull
      owners.append(
        (
          label,
          .obj([
            ("window", top.json), ("signature", signature),
            ("stack_owners", .strings(stack.prefix(5).compactMap(\.ownerName))),
          ])
        ))
      report.finding(
        "\(label): owner \(top.ownerName ?? "?") (layer \(top.layer ?? 0)), bundle id "
          + "\(signature["bundle_id"]?.stringValue ?? "NONE"), team \(signature["team_id"]?.stringValue ?? "none")"
      )
    }
    let desktop = windows.filter { ($0.layer ?? 0) < 0 }
    let desktopOwners = Set(desktop.compactMap(\.ownerPID))
    owners.append(
      (
        "desktop_level",
        .array(
          desktopOwners.sorted().map { pid in
            .obj([
              ("owner", .str(desktop.first { $0.ownerPID == pid }?.ownerName)),
              ("windows", .int(desktop.filter { $0.ownerPID == pid }.count)),
              ("signature", facts(pid)),
            ])
          })
      ))
    report.set("system_ui_owners", .obj(owners))

    // Named system processes.
    var system: [(String, JSON)] = []
    for name in ["WindowServer", "Dock", "SystemUIServer", "ControlCenter", "loginwindow", "Finder"] {
      let pids = windows.filter { $0.ownerName == name || $0.ownerName == "Window Server" && name == "WindowServer" }
        .compactMap(\.ownerPID)
      let pid =
        pids.first
        ?? NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?
        .processIdentifier
      system.append((name, pid.map(facts) ?? .obj([("running_with_windows", .bool(false))])))
    }
    report.set("system_processes", .obj(system))

    // Every regular app: Apple, Developer ID or Mac App Store, and the team-anchor check.
    var apps: [JSON] = []
    var masTotal = 0
    var masTeamAnchor = 0
    var appleNoTeam = 0
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      let signature = facts(app.processIdentifier)
      let requirements = signature["requirements"]
      let mas = requirements?["mac_app_store_leaf"]?.boolValue == true
      if mas {
        masTotal += 1
        if requirements?["team_anchor_leaf_ou"]?.boolValue == true { masTeamAnchor += 1 }
      }
      if requirements?["anchor_apple"]?.boolValue == true, signature["team_id"] == .null {
        appleNoTeam += 1
      }
      apps.append(
        .obj([
          ("bundle_id", .str(app.bundleIdentifier)),
          ("team_id", signature["team_id"].orNull),
          ("leaf_common_name", signature["leaf_common_name"].orNull),
          ("platform_identifier", signature["platform_identifier"].orNull),
          ("requirements", requirements.orNull),
          ("mas_receipt_present", signature["mas_receipt_present"].orNull),
        ]))
    }
    report.set("regular_apps", .array(apps))
    report.finding(
      "running Mac App Store apps: \(masTotal), of which \(masTeamAnchor) satisfy "
        + "'anchor apple generic and certificate leaf[subject.OU] = TEAM'")
    report.finding("running Apple apps with anchor apple and no team identifier: \(appleNoTeam)")
    if masTotal == 0 {
      report.note("no Mac App Store app was running: open one (e.g. from the App Store) and rerun")
    }
    return report
  }
}
