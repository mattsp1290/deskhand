import Foundation
import SpikeKit

/// Condenses the LaunchAgent's log into one result (items 1, 2, 4, 9 over time): when capture
/// checks failed or looked wallpaper-only, when permissions changed, and who connected.
enum AgentLog {
  static func report() -> ProbeReport {
    var report = ProbeReport("agent-log", items: ["1", "2", "9", "add-wallpaper-only"])
    let urls = [Agent.logURL.appendingPathExtension("1"), Agent.logURL]
    var lines: [JSON] = []
    for url in urls {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      lines += text.split(separator: "\n").compactMap { JSON.parse(String($0)) }
    }
    report.set("log", .string(Agent.logURL.path))
    report.set("lines", .int(lines.count))
    guard let first = lines.first, let last = lines.last else {
      report.skip("no agent log yet (is the LaunchAgent installed?)")
      return report
    }
    report.set("from", (first["t"]?["at"]).orNull)
    report.set("to", (last["t"]?["at"]).orNull)

    var checks = 0
    var failures: [JSON] = []
    var wallpaperOnly: [JSON] = []
    var permissionChanges: [JSON] = []
    var lastPermissions: JSON?
    var accepted: [JSON] = []
    var starts = 0
    var eventCounts: [String: Int] = [:]
    for line in lines {
      let kind = line["kind"]?.stringValue ?? ""
      let body = line["body"].orNull
      let at = (line["t"]?["at"]).orNull
      switch kind {
      case "start": starts += 1
      case "capture_check":
        checks += 1
        if body["shareable_content_error"] != nil || body["capture_error"] != nil {
          failures.append(.obj([("at", at), ("check", body)]))
        }
        if body["wallpaper_only_suspected"]?.boolValue == true {
          wallpaperOnly.append(.obj([("at", at), ("check", body)]))
        }
      case "sample":
        let permissions = body["permissions"]
        if let permissions, permissions != lastPermissions {
          permissionChanges.append(.obj([("at", at), ("permissions", permissions)]))
          lastPermissions = permissions
        }
      case "accept": accepted.append(body)
      case "event":
        eventCounts[body["event"]?.stringValue ?? "?", default: 0] += 1
      default: break
      }
    }
    report.set("agent_starts", .int(starts))
    report.set("capture_checks", .int(checks))
    report.set("capture_failures", .array(failures.suffix(50)))
    report.set("wallpaper_only", .array(wallpaperOnly.suffix(50)))
    report.set("permission_changes", .array(permissionChanges.suffix(50)))
    report.set("inbound_accepted", .array(accepted.suffix(50)))
    report.set(
      "event_counts", .obj(eventCounts.sorted { $0.key < $1.key }.map { ($0.key, .int($0.value)) }))
    report.finding(
      "agent log \(first["t"]?["at"]?.stringValue ?? "?") to \(last["t"]?["at"]?.stringValue ?? "?"): "
        + "\(checks) capture checks, \(failures.count) failed, \(wallpaperOnly.count) looked wallpaper-only"
    )
    report.finding(
      "permission readings changed \(max(0, permissionChanges.count - 1)) time(s); "
        + "\(accepted.count) inbound connection(s) accepted")
    let peers = Set(
      accepted.compactMap { $0["peer"]?.stringValue?.split(separator: ":").first.map(String.init) })
    if !peers.isEmpty { report.finding("inbound peers: \(peers.sorted().joined(separator: ", "))") }
    report.needsHuman = true
    report.note("rerun after days/weeks: the periodic consent prompt shows up as capture failures")
    return report
  }
}
