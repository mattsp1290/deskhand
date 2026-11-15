import Foundation
import SpikeKit

/// Item 4 snapshot: every lock, console and display-sleep candidate signal right now, plus the
/// settings that decide which lock paths the trials can drive (require-password delay, hot
/// corners, fast user switching).
enum SessionProbe {
  static let spec = ProbeSpec(
    name: "session", items: ["4", "lock-signal", "login-window"],
    summary: "session dictionary, lock candidates, console user, display sleep, lid, lock settings",
    run: run)

  /// Hot-corner action codes in com.apple.dock.
  static let cornerActions = [
    0: "none", 1: "none", 2: "mission_control", 3: "app_windows", 4: "desktop",
    5: "start_screen_saver", 6: "disable_screen_saver", 7: "dashboard", 10: "display_sleep",
    11: "launchpad", 12: "notification_center", 13: "lock_screen", 14: "quick_note",
  ]

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("session", items: spec.items)
    report.set("session_dictionary", .from(foundation: Signals.sessionDictionary()))
    report.set("lock_candidates", Signals.lockCandidates())
    report.set("io_console", Signals.ioConsole())
    report.set("console_user", Signals.consoleUser())
    report.set("displays", Signals.displaysAsleep())
    report.set("clamshell", Signals.clamshell())
    report.set("secure_input", Signals.secureInput())
    report.set("frontmost", .str(Signals.frontmostBundleID()))
    report.set("settings", settings())

    let lock = Signals.lockCandidates()
    let locked = (lock.members ?? []).filter { $0.value.boolValue == true }.map(\.key)
    report.finding(
      "candidates reading true now: \(locked.isEmpty ? "none" : locked.joined(separator: ", "))")
    let settings = report.evidence.first { $0.0 == "settings" }?.1
    if let corners = settings?["hot_corners"]?.members {
      let lockCorners = corners.filter { $0.value["action"]?.stringValue == "lock_screen" }
      report.finding(
        "hot corner for Lock Screen: "
          + (lockCorners.isEmpty ? "none set" : lockCorners.map(\.key).joined(separator: ", ")))
    }
    if let delay = settings?["screen_lock"]?.stringValue {
      report.finding("require password: \(delay)")
    }
    report.note("lock detection over 20 trials per path: trial lock")
    return report
  }

  static func settings() -> JSON {
    let screenLock = Shell.run("/usr/sbin/sysadminctl", ["-screenLock", "status"], timeout: 5)
    let lockText = (screenLock.stdout + screenLock.stderr)
      .split(separator: "\n").map(String.init)
      .first { $0.localizedCaseInsensitiveContains("screenLock") }
      .map { line in
        line.components(separatedBy: "] ").last ?? line
      }
    let pmset = Shell.run("/usr/bin/pmset", ["-g"], timeout: 5).stdout
      .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("sleep") || $0.hasPrefix("displaysleep") || $0.hasPrefix("lowpowermode") }
    var corners: [(String, JSON)] = []
    for corner in ["tl", "tr", "bl", "br"] {
      let action = CFPreferencesCopyAppValue("wvous-\(corner)-corner" as CFString, "com.apple.dock" as CFString)
      let modifier = CFPreferencesCopyAppValue("wvous-\(corner)-modifier" as CFString, "com.apple.dock" as CFString)
      let code = (action as? NSNumber)?.intValue
      corners.append(
        (
          corner,
          .obj([
            ("code", .int(code)), ("action", .str(code.flatMap { cornerActions[$0] })),
            ("modifier", .int((modifier as? NSNumber)?.intValue)),
          ])
        ))
    }
    let idleTime = CFPreferencesCopyValue(
      "idleTime" as CFString, "com.apple.screensaver" as CFString, kCFPreferencesCurrentUser,
      kCFPreferencesCurrentHost)
    let multipleSessions = CFPreferencesCopyValue(
      "MultipleSessionEnabled" as CFString, kCFPreferencesAnyApplication, kCFPreferencesAnyUser,
      kCFPreferencesCurrentHost)
    let users = Shell.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"], timeout: 5).stdout
      .split(separator: "\n").compactMap { line -> Int? in
        line.split(separator: " ", omittingEmptySubsequences: true).last.flatMap { Int($0) }
      }
      .filter { $0 >= 501 && $0 < 60_000 }
    return .obj([
      ("screen_lock", .str(lockText)),
      ("pmset", .strings(pmset)),
      ("hot_corners", .obj(corners)),
      ("screensaver_idle_time_s", .from(foundation: idleTime)),
      ("fast_user_switching_enabled", .from(foundation: multipleSessions)),
      ("local_user_accounts", .int(users.count)),
    ])
  }
}
