import AppKit
import Foundation

/// Notifications that might mark a lock, a display sleep or a console switch, with timestamps.
/// Observed on the main run loop; kept in a ring so trials can ask "what happened since N".
public final class SignalEvents {
  public static let shared = SignalEvents()

  private var events: [(seq: Int, json: JSON)] = []
  private var nextSeq = 1
  private var started = false
  private var tokens: [NSObjectProtocol] = []
  private var lastName: [String: String] = [:]
  /// Called for every event (the agent appends it to its log).
  public var onEvent: ((JSON) -> Void)?

  public static let distributedNames = [
    "com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
    "com.apple.screensaver.didstart", "com.apple.screensaver.willstop",
    "com.apple.screensaver.didstop", "com.apple.shieldWindowRaised",
    "com.apple.shieldWindowLowered", "com.apple.sessionAgent.sessionDidBecomeActive",
  ]

  public var lastSeq: Int { nextSeq - 1 }

  public func start() {
    guard !started else { return }
    started = true
    let distributed = DistributedNotificationCenter.default()
    for name in Self.distributedNames {
      tokens.append(
        distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { SignalEvents.shared.record(name) }
        })
    }
    let workspace = NSWorkspace.shared.notificationCenter
    let workspaceNames: [(Notification.Name, String)] = [
      (NSWorkspace.screensDidSleepNotification, "screens_did_sleep"),
      (NSWorkspace.screensDidWakeNotification, "screens_did_wake"),
      (NSWorkspace.willSleepNotification, "will_sleep"),
      (NSWorkspace.didWakeNotification, "did_wake"),
      (NSWorkspace.sessionDidResignActiveNotification, "session_did_resign_active"),
      (NSWorkspace.sessionDidBecomeActiveNotification, "session_did_become_active"),
    ]
    for (name, label) in workspaceNames {
      tokens.append(
        workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { SignalEvents.shared.record(label) }
        })
    }
    let app = NotificationCenter.default
    let appNames: [(Notification.Name, String)] = [
      (NSNotification.Name.NSApplicationProtectedDataWillBecomeUnavailable,
        "protected_data_will_become_unavailable"),
      (NSNotification.Name.NSApplicationProtectedDataDidBecomeAvailable,
        "protected_data_did_become_available"),
      (NSApplication.didChangeScreenParametersNotification, "screen_parameters_changed"),
    ]
    for (name, label) in appNames {
      tokens.append(
        app.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { SignalEvents.shared.record(label) }
        })
    }
  }

  public func record(_ name: String) {
    let event = JSON.obj([
      ("seq", .int(nextSeq)), ("event", .string(name)), ("at", .string(Clock.iso())),
      ("mono_ms", .double(Clock.monoMs().rounded())),
    ])
    events.append((nextSeq, event))
    nextSeq += 1
    if events.count > 500 { events.removeFirst(events.count - 500) }
    for group in Self.groups where group.contains(name) {
      lastName[group.joined(separator: "|")] = name
    }
    onEvent?(event)
  }

  private static let groups: [[String]] = [
    ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"],
    ["protected_data_will_become_unavailable", "protected_data_did_become_available"],
  ]

  /// The most recent of `names` seen since start, or `nil`.
  public func last(among names: [String]) -> String? {
    lastName[names.joined(separator: "|")]
  }

  public func since(_ seq: Int) -> [JSON] {
    events.filter { $0.seq > seq }.map(\.json)
  }
}
