import Foundation
import SpikeKit

/// What each spike item asks, for summary.md.
enum Items {
  static let titles: [(String, String)] = [
    ("1", "macOS version; periodic screen-recording prompt for a signed bundle using SCK only"),
    ("2", "permissions posting needs (Accessibility, Input Monitoring, post-event); restart after grant"),
    ("3", "grants survive installing a new build signed with the same identity"),
    ("4", "capture and input when locked, display asleep, lid closed, fast user switching, login window"),
    ("5", "a user-activity assertion wakes a sleeping display; does the lock screen follow"),
    ("6", "synthetic keys into password fields, unlock screen, auth prompt, System Settings"),
    ("7", "capture exclusion hides password manager and messaging apps; excluded apps still clickable"),
    ("8", "coordinate mapping: Retina, non-Retina external, display left of main, scaled"),
    ("9", "inbound LAN listener as a LaunchAgent and the Local Network prompt"),
    ("10", "Lima guest reachability (bean deskhand-ealq, not this harness)"),
    ("lock-signal", "which lock signal is right 20/20 per path and never says unlocked by mistake"),
    ("login-window", "login-window detection"),
    ("add-event-synthesizing", "a separate event-synthesizing grant"),
    ("add-remote-desktop", "the Remote Desktop privacy setting and how to detect it"),
    ("add-wallpaper-only", "LaunchAgent capture silently returning wallpaper or a redacted image"),
    ("add-blank-frame", "blank-frame detection from preflight plus SCShareableContent"),
    ("7t13-a", "a person-only HID idle signal that excludes deskhand's own posts"),
    ("7t13-b", "owner of the drag-image window during a real drag"),
    ("7t13-c", "Mac App Store apps vs 'anchor apple generic and leaf OU = TEAM'"),
    ("7t13-d", "click-through windows of allowed apps"),
    ("7t13-e", "keyboard-focus signal via the AX focused application"),
    ("7t13-apple-team", "Apple platform-binary team handling"),
    ("7t13-shortcuts", "default denied shortcuts incl. ctrl+f2/f3/f8 and ctrl+1..9"),
    ("7t13-echo", "50 ms own-post echo tolerance"),
    ("held-input", "held synthetic input after the posting process exits"),
    ("hotkeys", "posted modifier chords vs global hot keys; RegisterEventHotKey modifiers"),
    ("contract-73", "which processes own the menu bar, Dock and desktop; bundle identifiers"),
  ]
}

/// One manual step of the checklist, least effort first.
struct ChecklistEntry {
  let command: String
  let effort: Int
  let items: [String]
  let actions: String
  /// Result file relative to the Mac's results directory.
  let file: String
}

enum Checklist {
  static var entries: [ChecklistEntry] {
    var result: [ChecklistEntry] = []
    for trial in Catalog.trials where trial.name != "lock" {
      result.append(
        ChecklistEntry(
          command: "trial \(trial.name)", effort: trial.effort, items: trial.items,
          actions: trial.humanActions, file: "trials/\(trial.name).json"))
    }
    let lockEfforts = [
      "shortcut": 8, "display-sleep": 9, "hot-corner": 11, "menu": 15, "lid": 20,
      "fast-user-switch": 25, "idle": 30,
    ]
    for path in LockTrial.paths {
      let actions =
        path.automatic
        ? "unlock with Touch ID 20 times (the harness locks)"
        : "\(path.instruction) Then unlock. 20 times."
      result.append(
        ChecklistEntry(
          command: "trial lock --path \(path.name)", effort: lockEfforts[path.name] ?? 30,
          items: LockTrial.spec.items, actions: actions, file: "trials/lock-\(path.name).json"))
    }
    result.append(
      ChecklistEntry(
        command: "script persistence", effort: 2, items: ["3"],
        actions: "none (rebuilds, reinstalls with the same identity, compares grants)",
        file: "trials/persistence.json"))
    result.append(
      ChecklistEntry(
        command: "script agent-log", effort: 1, items: ["1"],
        actions: "none; rerun after a few days and after a week to catch the periodic prompt",
        file: "agent-log.json"))
    result.append(
      ChecklistEntry(
        command: "script remote", effort: 40, items: ["1", "2", "3", "4", "9"],
        actions: "repeat on m1max2021 (ssh lunus@10.0.0.96 once the key is added)",
        file: "../m1max2021/summary.md"))
    return result.sorted { $0.effort < $1.effort }
  }

  static func isDone(_ entry: ChecklistEntry, in directory: URL) -> Bool {
    let url = directory.appendingPathComponent(entry.file)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    guard entry.file.hasSuffix(".json"), let json = JSON.parse(text) else { return true }
    return json["evidence"]?["complete"]?.boolValue ?? true
  }

  static func print(directory: URL, idsOnly: Bool) {
    let pending = entries.filter { !isDone($0, in: directory) }
    if idsOnly {
      for entry in pending { Swift.print(entry.command) }
      return
    }
    Swift.print("Manual steps, least effort first ([x] = result recorded in \(directory.path)):")
    for (index, entry) in entries.enumerated() {
      let mark = isDone(entry, in: directory) ? "x" : " "
      Swift.print(
        " [\(mark)] \(index + 1). \(entry.command)  (items \(entry.items.joined(separator: ", ")))")
      Swift.print("        you: \(entry.actions)")
    }
    Swift.print(" [-] item 10 (Lima guest reachability) is bean deskhand-ealq; not run by this harness.")
    _ = pending
  }
}

/// Writes `summary.md` from every JSON result in a Mac's directory.
enum Summary {
  struct Loaded {
    let path: String
    let json: JSON
  }

  static func load(_ directory: URL) -> [Loaded] {
    var results: [Loaded] = []
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
      return []
    }
    for case let url as URL in enumerator where url.pathExtension == "json" {
      guard let text = try? String(contentsOf: url, encoding: .utf8), let json = JSON.parse(text),
        json["probe"] != nil
      else { continue }
      let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
      results.append(Loaded(path: relative, json: json))
    }
    return results.sorted { $0.path < $1.path }
  }

  static func write(directory: URL) -> URL {
    let results = load(directory)
    var lines: [String] = []
    let mac = results.first?.json["mac"]?.stringValue ?? directory.lastPathComponent
    let macos = results.first?.json["macos"]?.stringValue ?? "?"
    lines.append("# Spike results: \(mac)")
    lines.append("")
    lines.append(
      "Generated \(Clock.iso()) by `deskhand-spike summarize` from \(results.count) result files. "
        + "macOS \(macos).")
    let contexts = Set(results.compactMap { $0.json["context"]?["launched_by"]?.stringValue })
    let teams = Set(results.compactMap { $0.json["context"]?["team_id"]?.stringValue })
    lines.append(
      "Run contexts: \(contexts.sorted().joined(separator: ", ")); signing team(s): "
        + (teams.isEmpty ? "none (unsigned or ad-hoc)" : teams.sorted().joined(separator: ", "))
        + ".")
    lines.append("")
    lines.append("## By spike item")
    for (item, title) in Items.titles {
      lines.append("")
      lines.append("### \(item): \(title)")
      lines.append("")
      let covering = results.filter {
        $0.json["items"]?.arrayValue?.contains(.string(item)) == true
      }
      if item == "10" {
        lines.append("- Not covered here: bean deskhand-ealq runs it from the Lima guest.")
        continue
      }
      if covering.isEmpty {
        lines.append("- Not measured yet.")
        continue
      }
      for result in covering {
        let status = result.json["status"]?.stringValue ?? "?"
        let context = result.json["context"]?["launched_by"]?.stringValue ?? "?"
        let findings = result.json["findings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let human = result.json["needs_human"]?.boolValue == true ? ", needs a person" : ""
        lines.append("- `\(result.path)` (\(status), \(context)\(human))")
        for finding in findings { lines.append("  - \(finding)") }
        if status == "blocked_on_permission" {
          let blocked = result.json["blocked_on"]?.arrayValue?.compactMap(\.stringValue) ?? []
          lines.append("  - blocked on: \(blocked.joined(separator: ", "))")
        }
      }
    }
    lines.append("")
    lines.append("## Result files")
    lines.append("")
    lines.append("| file | status | context | blocked on | notes |")
    lines.append("| --- | --- | --- | --- | --- |")
    for result in results {
      let notes = (result.json["notes"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        .joined(separator: "; ").replacingOccurrences(of: "|", with: "/")
      let blocked = (result.json["blocked_on"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        .joined(separator: ", ")
      lines.append(
        "| `\(result.path)` | \(result.json["status"]?.stringValue ?? "?") | "
          + "\(result.json["context"]?["launched_by"]?.stringValue ?? "?") | \(blocked) | \(notes) |")
    }
    lines.append("")
    lines.append("## Manual steps")
    lines.append("")
    for entry in Checklist.entries {
      let done = Checklist.isDone(entry, in: directory)
      lines.append(
        "- [\(done ? "x" : " ")] `run-spike.sh \(entry.command)`: \(entry.actions) "
          + "(items \(entry.items.joined(separator: ", ")))")
    }
    let url = directory.appendingPathComponent("summary.md")
    try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
