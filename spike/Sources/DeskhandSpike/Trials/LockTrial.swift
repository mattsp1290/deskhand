import Foundation
import SpikeKit

enum LockTrial {
  static var spec: TrialSpec {
    TrialSpec(
      name: "lock", items: ["4", "lock-signal", "login-window"], effort: 10,
      summary: "20 lock/unlock cycles per path with every lock candidate sampled",
      humanActions: "unlock with Touch ID after each harness-triggered lock",
      run: run)
  }

  struct LockPath {
    let name: String
    let automatic: Bool
    let instruction: String
    let timeoutMs: Int
  }

  static let paths: [LockPath] = [
    LockPath(name: "shortcut", automatic: true, instruction: "", timeoutMs: 15_000),
    LockPath(name: "display-sleep", automatic: true, instruction: "", timeoutMs: 20_000),
    LockPath(name: "hot-corner", automatic: true, instruction: "", timeoutMs: 15_000),
    LockPath(
      name: "menu", automatic: false,
      instruction: "Choose Apple menu > Lock Screen now.", timeoutMs: 60_000),
    LockPath(
      name: "lid", automatic: false,
      instruction: "Close the lid, wait about 5 seconds, then open it.", timeoutMs: 120_000),
    LockPath(
      name: "fast-user-switch", automatic: false,
      instruction:
        "Open the user menu (Control Center > Fast User Switching) and choose Login Window…, "
        + "or switch to another account; then come back to this account.",
      timeoutMs: 120_000),
    LockPath(
      name: "idle", automatic: false,
      instruction: "Hands off: wait for the display to sleep on its own (pmset displaysleep).",
      timeoutMs: 1_800_000),
  ]

  static let strong = [
    "session_screen_is_locked", "io_console_users_screen_locked", "loginwindow_shield",
  ]

  static func looksLocked(_ sample: JSON) -> Bool {
    let lock = sample["lock"]
    if lock?["on_console"]?.boolValue == false { return true }
    return strong.contains { lock?[$0]?.boolValue == true }
  }

  static func looksUnlocked(_ sample: JSON) -> Bool {
    let lock = sample["lock"]
    guard lock?["on_console"]?.boolValue == true else { return false }
    return strong.allSatisfy { lock?[$0]?.boolValue == false }
  }

  static func run(_ env: TrialEnv) async throws {
    let pathName = env.options["path"] ?? "shortcut"
    guard let path = paths.first(where: { $0.name == pathName }) else {
      env.say("unknown --path \(pathName); one of: \(paths.map(\.name).joined(separator: ", "))")
      return
    }
    env.report = ProbeReport("trial-lock-\(path.name)", items: spec.items)
    var corner: String?
    if path.name == "hot-corner" {
      corner = try await lockCorner(env)
      guard corner != nil else { return }
    }
    if path.name == "display-sleep" || path.name == "idle" {
      let lockSetting = SessionProbe.settings()["screen_lock"]?.stringValue ?? "unknown"
      env.say("Require password setting: \(lockSetting)")
      if !lockSetting.localizedCaseInsensitiveContains("immediate") {
        env.say(
          "Display sleep only locks when the password is required immediately "
            + "(System Settings > Lock Screen). Trials still run and record what happens.")
      }
    }
    env.step(
      "Lock path '\(path.name)': \(env.count) trials. "
        + (path.automatic
          ? "The harness locks the Mac each time; you only unlock (Touch ID). Do not type a password into anything this harness shows you."
          : path.instruction + " Then unlock (Touch ID)."))
    try await env.waitEnter("Ready")

    var detected: [String: Int] = [:]
    var falseUnlocks: [String: Int] = [:]
    var latencies: [String: [Double]] = [:]
    for attempt in 1...env.count {
      env.say("\n[\(path.name) \(attempt)/\(env.count)]")
      var pre = try await env.sample()
      if !looksUnlocked(pre) {
        env.say("Waiting for the Mac to be unlocked…")
        _ = try await env.poll(everyMs: 500, timeoutMs: 300_000) { looksUnlocked($0) }
        pre = try await env.sample()
      }
      let t0 = Clock.monoMs()
      var trigger: JSON = .null
      switch path.name {
      case "shortcut": trigger = try await env.act("lock-shortcut")
      case "display-sleep": trigger = try await env.act("display-sleep")
      case "hot-corner": trigger = try await env.act("hot-corner", corner ?? "tl")
      default: env.say(path.instruction)
      }
      var samples = try await env.poll(everyMs: 200, timeoutMs: path.timeoutMs) { looksLocked($0) }
      let sawLock = samples.last.map(looksLocked) ?? false
      if sawLock { samples += try await env.poll(everyMs: 200, timeoutMs: 3000) }
      var during: [JSON] = []
      if sawLock {
        during.append(try await env.act("nudge-pointer"))
        during.append(try await env.act("capture-check"))
        samples.append(try await env.sample())
        env.say("Locked. Unlock now (Touch ID).")
      } else {
        env.say("No candidate reported a lock within \(path.timeoutMs / 1000) s.")
      }
      let unlockStart = samples.count
      samples += try await env.poll(everyMs: 300, timeoutMs: 600_000) { looksUnlocked($0) }
      if !(samples.last.map(looksUnlocked) ?? false) {
        try await env.waitEnter("Unlock was not detected. Unlock, then")
      }
      await Clock.sleep(ms: 1500)
      let post = try await env.sample()
      var humanSaysLocked: String?
      if !sawLock {
        humanSaysLocked = try await env.ask(
          "attempt\(attempt)_screen_locked", "Did the screen lock?")
      }

      let timeline = timelines(samples, t0: t0)
      let analysis = analyse(samples, t0: t0, lockedPhaseEnd: unlockStart)
      for member in analysis.members ?? [] {
        detected[member.key, default: 0] += 0
        if let ms = member.value["first_locked_ms"]?.doubleValue {
          detected[member.key, default: 0] += 1
          latencies[member.key, default: []].append(ms)
        }
        if (member.value["false_unlocked_samples"]?.intValue ?? 0) > 0 {
          falseUnlocks[member.key, default: 0] += 1
        }
      }
      let lastSeq = pre["last_seq"]?.intValue ?? 0
      let events = try await (env.call(["sample", String(lastSeq)]).last?["events"]).orNull
      try env.record(
        .obj([
          ("attempt", .int(attempt)), ("path", .string(path.name)), ("trigger", trigger),
          ("pre", pre), ("saw_lock", .bool(sawLock)), ("human_says_locked", .str(humanSaysLocked)),
          ("analysis", analysis), ("timeline", timeline), ("samples", .array(samples)),
          ("during_lock", .array(during)),
          ("events", events), ("post", post),
        ]))
      await Clock.sleep(ms: 2000)
    }
    for key in Set(latencies.keys).union(detected.keys).union(falseUnlocks.keys).sorted() {
      let values = (latencies[key] ?? []).sorted()
      let median = values.isEmpty ? nil : values[values.count / 2]
      env.report.finding(
        "\(path.name): \(key) saw the lock in \(detected[key] ?? 0)/\(env.count), candidate disagreement attempts "
          + "(independent reference pending) in \(falseUnlocks[key] ?? 0), median latency "
          + (median.map { "\(Int($0)) ms" } ?? "n/a"))
    }
    env.report.status = .inconclusive
    env.report.note(
      "Candidate agreement is not an independent locked interval. Safety qualification remains pending independent reference timing."
    )
    try env.finish()
  }

  static func analyse(_ samples: [JSON], t0: Double, lockedPhaseEnd: Int) -> JSON {
    let locked = Set(samples.indices.filter { $0 < lockedPhaseEnd && looksLocked(samples[$0]) })
    return MeasurementAnalysis.lock(
      samples, t0: t0,
      reference: LockReference(provenance: .candidateAgreement, lockedIndices: locked))
  }

  static func timelines(_ samples: [JSON], t0: Double) -> JSON {
    let keys = samples.first?["lock"]?.members?.map(\.key) ?? []
    var result: [(String, JSON)] = []
    for key in keys {
      var last: JSON?
      var changes: [JSON] = []
      for sample in samples {
        let value = (sample["lock"]?[key]).orNull
        if value != last {
          let at = (sample["t"]?["mono_ms"]?.doubleValue ?? t0) - t0
          changes.append(.obj([("ms", .double(at.rounded())), ("value", value)]))
          last = value
        }
      }
      result.append((key, .array(changes)))
    }
    let asleep = samples.map { sample -> JSON in
      .bool(sample["displays"]?.arrayValue?.contains { $0["asleep"]?.boolValue == true } ?? false)
    }
    var sleepChanges: [JSON] = []
    var last: JSON?
    for (sample, value) in zip(samples, asleep) where value != last {
      let at = (sample["t"]?["mono_ms"]?.doubleValue ?? t0) - t0
      sleepChanges.append(.obj([("ms", .double(at.rounded())), ("value", value)]))
      last = value
    }
    result.append(("any_display_asleep", .array(sleepChanges)))
    return .obj(result)
  }

  private static func lockCorner(_ env: TrialEnv) async throws -> String? {
    while true {
      let corners = SessionProbe.settings()["hot_corners"]?.members ?? []
      if let corner = corners.first(where: {
        $0.value["action"]?.stringValue == "lock_screen"
          && ($0.value["modifier"]?.intValue ?? 0) == 0
      }) {
        env.say("Using the \(corner.key) hot corner (set to Lock Screen).")
        return corner.key
      }
      _ = try await env.act(
        "open-settings", "x-apple.systempreferences:com.apple.Desktop-Settings.extension")
      env.say(
        "No hot corner is set to Lock Screen (without a modifier). In Desktop & Dock > Hot "
          + "Corners…, set one corner to Lock Screen.")
      let answer = try await env.ask("hot_corner_configured", "Done?", choices: ["y", "skip"])
      if answer == "skip" { return nil }
    }
  }
}
