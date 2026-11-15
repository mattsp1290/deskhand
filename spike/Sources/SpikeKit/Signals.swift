import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import SystemConfiguration

/// Point-in-time readings of every state signal the spike compares: permissions, idle counters,
/// session and lock candidates, display sleep, secure input and the lid.
public enum Signals {
  /// `kCGAnyInputEventType`; imported C enums accept any raw value.
  public static let anyInputEvent = CGEventType(rawValue: ~0)!

  // MARK: Permissions

  public static func preflights() -> JSON {
    .obj([
      ("screen_recording", .bool(CGPreflightScreenCaptureAccess())),
      ("post_event", .bool(CGPreflightPostEventAccess())),
      ("listen_event", .bool(CGPreflightListenEventAccess())),
      ("accessibility", .bool(AXIsProcessTrusted())),
      ("iohid_post_event", .string(accessName(IOHIDCheckAccess(kIOHIDRequestTypePostEvent)))),
      ("iohid_listen_event", .string(accessName(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)))),
    ])
  }

  public static func granted(_ permission: Permission) -> Bool {
    switch permission {
    case .screenRecording: CGPreflightScreenCaptureAccess()
    case .postEvent: CGPreflightPostEventAccess()
    case .accessibility: AXIsProcessTrusted()
    case .listenEvent: CGPreflightListenEventAccess()
    }
  }

  private static func accessName(_ access: IOHIDAccessType) -> String {
    switch access {
    case kIOHIDAccessTypeGranted: "granted"
    case kIOHIDAccessTypeDenied: "denied"
    default: "unknown"
    }
  }

  // MARK: Idle counters

  /// Seconds since the last input event, by source and type, plus IOHIDSystem's `HIDIdleTime`.
  public static func idle() -> JSON {
    func seconds(_ state: CGEventSourceStateID, _ type: CGEventType) -> JSON {
      .double(CGEventSource.secondsSinceLastEventType(state, eventType: type))
    }
    return .obj([
      ("hid_any_s", seconds(.hidSystemState, anyInputEvent)),
      ("combined_any_s", seconds(.combinedSessionState, anyInputEvent)),
      ("hid_mouse_moved_s", seconds(.hidSystemState, .mouseMoved)),
      ("hid_key_down_s", seconds(.hidSystemState, .keyDown)),
      ("combined_mouse_moved_s", seconds(.combinedSessionState, .mouseMoved)),
      ("combined_key_down_s", seconds(.combinedSessionState, .keyDown)),
      ("iohid_idle_s", .num(hidIdleSeconds())),
    ])
  }

  public static func hidIdleSeconds() -> Double? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(
      service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    return (value as? NSNumber).map { $0.doubleValue / 1_000_000_000 }
  }

  // MARK: Session, lock and console

  public static func sessionDictionary() -> [String: Any] {
    (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
  }

  public static func consoleUser() -> JSON {
    var uid: uid_t = 0
    var gid: gid_t = 0
    let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?
    return .obj([("name", .str(name)), ("uid", .int(Int(uid)))])
  }

  /// IORegistry root `IOConsoleLocked` and this user's `IOConsoleUsers` entry. Both are readable
  /// by any process, including a root daemon with no window-server connection.
  public static func ioConsole() -> JSON {
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    func property(_ name: String) -> Any? {
      IORegistryEntryCreateCFProperty(root, name as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    }
    let users = (property("IOConsoleUsers") as? [[String: Any]]) ?? []
    let mine = users.first { ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == getuid() }
    return .obj([
      ("console_locked", .from(foundation: property("IOConsoleLocked"))),
      ("console_user_count", .int(users.count)),
      ("my_entry_screen_locked", .from(foundation: mine?["CGSSessionScreenIsLocked"])),
      ("my_entry_on_console", .from(foundation: mine?["kCGSSessionOnConsoleKey"])),
    ])
  }

  public static func clamshell() -> JSON {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return .null }
    defer { IOObjectRelease(service) }
    func property(_ name: String) -> JSON {
      .from(
        foundation: IORegistryEntryCreateCFProperty(
          service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
    }
    return .obj([
      ("closed", property("AppleClamshellState")),
      ("causes_sleep", property("AppleClamshellCausesSleep")),
    ])
  }

  public static func displaysAsleep() -> JSON {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return .array(
      ids.prefix(Int(count)).map { id in
        .obj([
          ("id", .int(Int(id))), ("asleep", .bool(CGDisplayIsAsleep(id) != 0)),
          ("main", .bool(CGDisplayIsMain(id) != 0)), ("active", .bool(CGDisplayIsActive(id) != 0)),
        ])
      })
  }

  public static func secureInput() -> JSON {
    let session = sessionDictionary()
    return .obj([
      ("enabled", .bool(IsSecureEventInputEnabled())),
      ("session_secure_input_pid", .from(foundation: session["kCGSSessionSecureInputPID"])),
    ])
  }

  /// Windows the login window has on screen at or above the shielding level: the lock screen.
  public static func loginwindowShield() -> JSON {
    let shield = Int(CGShieldingWindowLevel())
    let windows = WindowList.onScreen().filter { $0.ownerName == "loginwindow" }
    let high = windows.filter { ($0.layer ?? Int.min) >= shield }
    return .obj([
      ("windows", .int(windows.count)), ("at_or_above_shield", .int(high.count)),
      ("max_layer", .int(windows.compactMap(\.layer).max())),
    ])
  }

  public static func frontmostBundleID() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
  }

  public static func screenSaverRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
      $0.bundleIdentifier?.hasPrefix("com.apple.ScreenSaver") == true
    }
  }

  /// Every lock-detection candidate as a flat object of booleans and strings. `true` means
  /// "locked" for the boolean candidates.
  public static func lockCandidates() -> JSON {
    let session = sessionDictionary()
    let io = ioConsole()
    let shield = loginwindowShield()
    let lastLockEvent = SignalEvents.shared.last(among: [
      "com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
    ])
    let lastProtected = SignalEvents.shared.last(among: [
      "protected_data_will_become_unavailable", "protected_data_did_become_available",
    ])
    return .obj([
      ("session_screen_is_locked", .bool((session["CGSSessionScreenIsLocked"] as? Bool) == true)),
      ("io_console_locked", .bool(io["console_locked"]?.boolValue == true)),
      ("io_console_users_screen_locked", .bool(io["my_entry_screen_locked"]?.boolValue == true)),
      (
        "notification_says_locked",
        lastLockEvent.map { .bool($0 == "com.apple.screenIsLocked") } ?? .null
      ),
      ("protected_data_unavailable", .bool(!NSApplication.shared.isProtectedDataAvailable)),
      (
        "protected_data_notification_says_unavailable",
        lastProtected.map { .bool($0 == "protected_data_will_become_unavailable") } ?? .null
      ),
      ("loginwindow_shield", .bool((shield["at_or_above_shield"]?.intValue ?? 0) > 0)),
      ("screensaver_running", .bool(screenSaverRunning())),
      ("frontmost_is_loginwindow", .bool(frontmostBundleID() == "com.apple.loginwindow")),
      ("on_console", .bool((session["kCGSSessionOnConsoleKey"] as? Bool) == true)),
    ])
  }

  /// One sample of everything; the agent logs these and the trials poll them.
  public static func sample() -> JSON {
    .obj([
      ("t", Clock.stamp()),
      ("lock", lockCandidates()),
      ("console_user", consoleUser()),
      ("displays", displaysAsleep()),
      ("clamshell", clamshell()),
      ("secure_input", secureInput()),
      ("idle", idle()),
      ("permissions", preflights()),
      ("frontmost", .str(frontmostBundleID())),
      ("session_locked_time", .from(foundation: sessionDictionary()["CGSSessionScreenLockedTime"])),
    ])
  }

  /// Whether input probes may post: on the console, unlocked by every candidate, display awake.
  public static func safeToPost() -> (Bool, String) {
    let lock = lockCandidates()
    if lock["on_console"]?.boolValue != true { return (false, "session is not on the console") }
    for key in ["session_screen_is_locked", "io_console_users_screen_locked", "loginwindow_shield"]
    where lock[key]?.boolValue == true {
      return (false, "screen looks locked (\(key))")
    }
    if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return (false, "main display is asleep") }
    return (true, "ok")
  }
}
