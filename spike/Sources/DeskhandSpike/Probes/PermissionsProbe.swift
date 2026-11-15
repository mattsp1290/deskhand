import Foundation
import SQLite3
import SpikeKit

/// Item 2 and the spike additions on a separate event-synthesizing grant and the Remote Desktop
/// setting: the preflight APIs, which TCC services this macOS knows, and (only when the
/// responsible process has Full Disk Access) deskhand's rows in the TCC databases.
enum PermissionsProbe {
  static let spec = ProbeSpec(
    name: "permissions", items: ["2", "3", "add-event-synthesizing", "add-remote-desktop"],
    summary: "permission preflights, TCC services known to tccd, deskhand's TCC rows if readable",
    run: run)

  static let services = [
    "kTCCServiceScreenCapture", "kTCCServiceRemoteDesktop", "kTCCServicePostEvent",
    "kTCCServiceListenEvent", "kTCCServiceAccessibility", "kTCCServiceDeveloperTool",
  ]

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("permissions", items: spec.items)
    let preflights = Signals.preflights()
    report.set("preflights", preflights)

    let tccd = "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd"
    let binary = FileManager.default.contents(atPath: tccd) ?? Data()
    let known = services.map { name in
      (name, JSON.bool(binary.range(of: Data(name.utf8)) != nil))
    }
    report.set("tccd_services", .obj(known))
    report.set("tcc_prompt_strings", promptStrings())
    report.set(
      "tcc_databases",
      .obj([
        ("user", readTCC(NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db")),
        ("system", readTCC("/Library/Application Support/com.apple.TCC/TCC.db")),
      ]))

    func word(_ key: String) -> String {
      preflights[key]?.boolValue == true ? "granted" : "not granted"
    }
    report.finding(
      "preflights: screen recording \(word("screen_recording")), post event \(word("post_event")), "
        + "accessibility \(word("accessibility")), input monitoring \(word("listen_event"))")
    let postEvent = known.first { $0.0 == "kTCCServicePostEvent" }?.1.boolValue == true
    let remote = known.first { $0.0 == "kTCCServiceRemoteDesktop" }?.1.boolValue == true
    report.finding(
      "tccd knows kTCCServicePostEvent (the event-synthesizing service behind "
        + "CGRequestPostEventAccess): \(postEvent ? "yes" : "no")")
    report.finding(
      "tccd knows kTCCServiceRemoteDesktop: \(remote ? "yes" : "no"); whether System Settings "
        + "shows it as its own list is asked in the permissions trial")
    if RunContext.launchedBy == .terminal {
      report.note(
        "run from a terminal: the preflights above are the terminal app's grants, not deskhand's")
    }
    report.needsHuman = true
    report.note("which grant posting needs and whether a restart is needed: trial permissions")
    return report
  }

  /// The localized prompt texts for the capture services (shows whether Remote Desktop has its
  /// own consent text).
  private static func promptStrings() -> JSON {
    let path =
      "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/Resources/Localizable.loctable"
    guard let data = FileManager.default.contents(atPath: path),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let english = plist["en"] as? [String: Any]
    else { return .null }
    let keys = english.keys.filter {
      $0.contains("kTCCServiceRemoteDesktop") || $0.contains("kTCCServiceScreenCapture")
        || $0.contains("kTCCServicePostEvent")
    }
    return .obj(keys.sorted().map { ($0, .from(foundation: english[$0])) })
  }

  /// deskhand's rows in a TCC database. Reading needs Full Disk Access for the responsible
  /// process, so "unreadable" is the normal answer.
  private static func readTCC(_ path: String) -> JSON {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
      sqlite3_close(db)
      return .obj([("readable", .bool(false)), ("error", .string("open failed"))])
    }
    defer { sqlite3_close(db) }
    let sql =
      "SELECT service, auth_value, auth_reason, last_modified FROM access WHERE client = ?"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      let message = String(cString: sqlite3_errmsg(db))
      return .obj([("readable", .bool(false)), ("error", .string(message))])
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, RunContext.bundleIdentifier, -1, transient)
    var rows: [JSON] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let service = sqlite3_column_text(statement, 0).map { String(cString: $0) }
      rows.append(
        .obj([
          ("service", .str(service)),
          ("auth_value", .int(Int(sqlite3_column_int(statement, 1)))),
          ("auth_reason", .int(Int(sqlite3_column_int(statement, 2)))),
          ("last_modified", .int(Int(sqlite3_column_int64(statement, 3)))),
        ]))
    }
    return .obj([("readable", .bool(true)), ("rows", .array(rows))])
  }
}
