import CryptoKit
import Darwin
import Foundation
import SpikeKit

enum Items {
  static let titles: [(String, String)] = [
    ("1", "macOS version; periodic screen-recording prompt for a signed bundle using SCK only"),
    (
      "2",
      "permissions posting needs (Accessibility, Input Monitoring, post-event); restart after grant"
    ),
    ("3", "grants survive installing a new build signed with the same identity"),
    (
      "4",
      "capture and input when locked, display asleep, lid closed, fast user switching, login window"
    ),
    ("5", "a user-activity assertion wakes a sleeping display; does the lock screen follow"),
    ("6", "synthetic keys into password fields, unlock screen, auth prompt, System Settings"),
    (
      "7",
      "capture exclusion hides password manager and messaging apps; excluded apps still clickable"
    ),
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

struct ChecklistEntry {
  let command: String
  let effort: Int
  let items: [String]
  let actions: String
  let file: String
}

enum Checklist {
  static var entries: [ChecklistEntry] {
    var result: [ChecklistEntry] = []
    for trial in Catalog.trials where trial.name != "lock" {
      result.append(
        ChecklistEntry(
          command: "--trial \(trial.name)", effort: trial.effort, items: trial.items,
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
          command: "--trial lock --path \(path.name) --count 20",
          effort: lockEfforts[path.name] ?? 30,
          items: LockTrial.spec.items, actions: actions, file: "trials/lock-\(path.name).json"))
    }
    result.append(
      ChecklistEntry(
        command: "", effort: 2, items: ["3"],
        actions:
          "Pending external work. Ask the signing Mac for a second same-identity signed/notarized artifact and receipt. Preserve both receipts and before/after permission reports, install with spike/scripts/install.sh, then compare grants and artifact IDs.",
        file: "external-persistence"))
    result.append(
      ChecklistEntry(
        command: "--automatic", effort: 1, items: ["1"],
        actions:
          "Rerun after a few days and a week, then inspect the recorded agent log for the periodic prompt.",
        file: "external-periodic-prompt"))
    result.append(
      ChecklistEntry(
        command: "", effort: 40, items: ["9"],
        actions:
          "Run spike/scripts/run-spike.sh --host TARGET --peer USER@OTHER_HOST --peer-listener. Use distinct physical hosts; inspect correlated source, destination and nonce evidence.",
        file: "peer-listener.json"))
    return result.sorted { $0.effort < $1.effort }
  }

  static func command(_ entry: ChecklistEntry, host: String) -> String {
    guard !entry.command.isEmpty else { return "Pending external work" }
    let quoted = "'" + host.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return "spike/scripts/run-spike.sh --host \(quoted) \(entry.command)"
  }

  static func isDone(_ entry: ChecklistEntry, in directory: URL) -> Bool {
    guard let url = Campaign.selected(entry.file, in: directory) else { return false }
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    guard entry.file.hasSuffix(".json"), let json = JSON.parse(text) else { return false }
    return json["status"]?.stringValue == "measured"
      && (!entry.file.hasPrefix("trials/") || json["evidence"]?["complete"]?.boolValue == true)
  }

  static func print(directory: URL, idsOnly: Bool) {
    let pending = entries.filter { !isDone($0, in: directory) }
    if idsOnly {
      for entry in pending { Swift.print(command(entry, host: directory.lastPathComponent)) }
      return
    }
    Swift.print("Manual steps, least effort first ([x] = result recorded in \(directory.path)):")
    for (index, entry) in entries.enumerated() {
      let mark = isDone(entry, in: directory) ? "x" : " "
      Swift.print(
        " [\(mark)] \(index + 1). \(command(entry, host: directory.lastPathComponent))  (items \(entry.items.joined(separator: ", ")))"
      )
      Swift.print("        you: \(entry.actions)")
    }
    Swift.print(
      " [-] item 10 (Lima guest reachability) is bean deskhand-ealq; not run by this harness.")
    _ = pending
  }
}

enum Campaign {
  static func read(_ directory: URL) -> JSON? {
    (try? String(contentsOf: directory.appendingPathComponent("campaign.json"), encoding: .utf8))
      .flatMap(JSON.parse)
  }

  static func selected(_ file: String, in directory: URL) -> URL? {
    guard let run = read(directory)?["selected"]?[file]?.stringValue,
      safeRun(run), !file.contains(".."), !file.hasPrefix("/")
    else { return nil }
    return directory.appendingPathComponent("runs/\(run)/\(file)")
  }

  static func safeRun(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
  }

  static func importRun(_ runID: String, into directory: URL) throws {
    guard safeRun(runID) else { throw TrialAbort.failed("invalid invocation name") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fd = open(directory.appendingPathComponent(".campaign.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw TrialAbort.failed("cannot open campaign writer lock") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else {
      throw TrialAbort.failed("cannot acquire campaign writer lock")
    }
    defer { flock(fd, LOCK_UN) }
    let run = directory.appendingPathComponent("runs/\(runID)")
    let receiptData = try Data(contentsOf: run.appendingPathComponent("artifact-receipt.json"))
    let receipt = try JSONSerialization.jsonObject(with: receiptData)
    guard let fields = receipt as? [String: Any],
      let digest = fields["executable_sha256"] as? String,
      digest.count == 64, fields["source_sha"] != nil, fields["team"] != nil
    else {
      throw TrialAbort.failed("invocation lacks artifact receipt provenance")
    }
    let canonical = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
    let artifact = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    let archive = directory.appendingPathComponent("campaigns/\(artifact).json")
    let prior: JSON?
    if FileManager.default.fileExists(atPath: archive.path) {
      let text = try String(contentsOf: archive, encoding: .utf8)
      guard let saved = JSON.parse(text), saved["artifact_id"]?.stringValue == artifact,
        saved["invocations"]?.arrayValue != nil, saved["selected"]?.members != nil
      else {
        throw TrialAbort.failed("existing campaign is malformed; preserve it for inspection")
      }
      prior = saved
    } else {
      prior = nil
    }
    var attempts = prior?["invocations"]?.arrayValue ?? []
    var selected = prior?["selected"]?.members?.map { ($0.key, $0.value) } ?? []
    let invocation = try String(
      contentsOf: run.appendingPathComponent("invocation.json"), encoding: .utf8)
    guard let outcome = JSON.parse(invocation), let status = outcome["exit_status"]?.intValue else {
      throw TrialAbort.failed("missing invocation outcome")
    }
    let reports = Summary.loadFiles(run)
    if !attempts.contains(where: { $0["id"]?.stringValue == runID }) {
      attempts.append(
        .obj([
          ("id", .string(runID)), ("exit_status", .int(status)),
          ("reports", .strings(reports.map(\.path))),
        ]))
      if status == 0 {
        for report in reports
        where report.json["status"]?.stringValue == "measured"
          && (!report.path.hasPrefix("trials/")
            || report.json["evidence"]?["complete"]?.boolValue == true)
        {
          selected.removeAll { $0.0 == report.path }
          selected.append((report.path, .string(runID)))
        }
      }
    }
    let campaign = JSON.obj([
      ("artifact_id", .string(artifact)),
      ("receipt", JSON.parse(String(decoding: canonical, as: UTF8.self)).orNull),
      ("invocations", .array(attempts)), ("selected", .obj(selected)),
    ])
    try EvidenceWriter.write(campaign.pretty(), to: archive)
    try EvidenceWriter.write(
      campaign.pretty(), to: directory.appendingPathComponent("campaign.json"))
    try EvidenceWriter.write(runID + "\n", to: directory.appendingPathComponent("current-run"))
  }
}

enum RunDirectory {
  static func selected(in directory: URL) -> URL {
    let pointer = directory.appendingPathComponent("current-run")
    guard let text = try? String(contentsOf: pointer, encoding: .utf8) else { return directory }
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return directory }
    return directory.appendingPathComponent("runs").appendingPathComponent(name)
  }
}

enum Summary {
  struct Loaded {
    let path: String
    let json: JSON
  }

  static func load(_ directory: URL) -> [Loaded] {
    guard let campaign = Campaign.read(directory) else {
      return loadFiles(RunDirectory.selected(in: directory))
    }
    var results: [Loaded] = []
    for selection in campaign["selected"]?.members ?? [] {
      guard let url = Campaign.selected(selection.key, in: directory),
        let text = try? String(contentsOf: url, encoding: .utf8), let json = JSON.parse(text)
      else { continue }
      results.append(
        Loaded(path: "runs/\(selection.value.stringValue ?? "")/\(selection.key)", json: json))
    }
    return results.sorted { $0.path < $1.path }
  }

  static func loadFiles(_ requestedDirectory: URL) -> [Loaded] {
    let directory = requestedDirectory.resolvingSymlinksInPath()
    var results: [Loaded] = []
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(atPath: directory.path) else {
      return []
    }
    for case let relative as String in enumerator {
      let url = directory.appendingPathComponent(relative)
      if url.lastPathComponent == "runs" {
        enumerator.skipDescendants()
        continue
      }
      guard url.pathExtension == "json" else { continue }
      guard let text = try? String(contentsOf: url, encoding: .utf8), let json = JSON.parse(text),
        json["probe"] != nil
      else { continue }
      results.append(Loaded(path: relative, json: json))
    }
    return results.sorted { $0.path < $1.path }
  }

  static func executionContext(_ json: JSON) -> JSON {
    json["evidence"]?["measurement_context"]
      ?? json["evidence"]?["executor_context"]
      ?? json["context"] ?? .null
  }

  static func write(directory: URL) throws -> URL {
    let results = load(directory)
    var lines: [String] = []
    let mac = results.first?.json["mac"]?.stringValue ?? directory.lastPathComponent
    let macos = results.first?.json["macos"]?.stringValue ?? "?"
    lines.append("# Spike results: \(mac)")
    lines.append("")
    lines.append(
      "Generated \(Clock.iso()) by `deskhand-spike summarize` from \(results.count) result files. "
        + "macOS \(macos).")
    let contexts = Set(results.compactMap { executionContext($0.json)["launched_by"]?.stringValue })
    let teams = Set(results.compactMap { executionContext($0.json)["team_id"]?.stringValue })
    lines.append(
      "Run contexts: \(contexts.sorted().joined(separator: ", ")); signing team(s): "
        + (teams.isEmpty ? "none (unsigned or ad-hoc)" : teams.sorted().joined(separator: ", "))
        + ".")
    lines.append("")
    if let campaign = Campaign.read(directory) {
      lines.append("Campaign artifact \(campaign["artifact_id"]?.stringValue ?? "unknown").")
      for attempt in campaign["invocations"]?.arrayValue ?? [] {
        lines.append(
          "- Invocation \(attempt["id"]?.stringValue ?? "?") exited \(attempt["exit_status"]?.intValue ?? -1). Evidence remains in its run directory."
        )
        if attempt["exit_status"]?.intValue != 0 {
          for file in attempt["reports"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            lines.append(
              "  - Failed invocation evidence: `runs/\(attempt["id"]?.stringValue ?? "?")/\(file)`. This attempt does not replace successful selections."
            )
          }
        }
      }
      lines.append("")
    }
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
        let context = executionContext(result.json)["launched_by"]?.stringValue ?? "?"
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
          + "\(executionContext(result.json)["launched_by"]?.stringValue ?? "?") | \(blocked) | \(notes) |"
      )
    }
    lines.append("")
    lines.append("## Manual steps")
    lines.append("")
    for entry in Checklist.entries {
      let done = Checklist.isDone(entry, in: directory)
      lines.append(
        "- [\(done ? "x" : " ")] `\(Checklist.command(entry, host: directory.lastPathComponent))`: \(entry.actions) "
          + "(items \(entry.items.joined(separator: ", ")))")
    }
    let url = directory.appendingPathComponent("summary.md")
    try EvidenceWriter.write(lines.joined(separator: "\n") + "\n", to: url)
    return url
  }
}
