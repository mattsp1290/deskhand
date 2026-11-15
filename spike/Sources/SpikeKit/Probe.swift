import Foundation

/// How a probe ended. Only `measured` means the evidence answers the question it was built for.
public nonisolated enum ProbeStatus: String, Sendable {
  /// The probe ran and recorded evidence.
  case measured
  case inconclusive
  /// A permission the probe needs is not granted; the evidence shows which and what failed.
  case blockedOnPermission = "blocked_on_permission"
  /// The probe did not run because the Mac was in a state where running it would be unsafe or
  /// meaningless (for example, input probes while the screen is locked).
  case skipped
  /// Something unexpected went wrong.
  case error
}

/// The macOS permissions the harness asks about. The names are the ones results use.
public nonisolated enum Permission: String, Sendable, CaseIterable {
  case screenRecording = "screen_recording"
  case postEvent = "post_event"
  case accessibility
  case listenEvent = "listen_event"
}

/// Options shared by every probe, parsed from the command line.
public struct ProbeOptions: Sendable {
  /// Extra bundle identifiers to test capture exclusion against (repeatable
  /// `--exclude-bundle-id`).
  public var excludeBundleIDs: [String] = []
  /// Directory for capture images meant for a human to look at; never inside the repository.
  public var imageDirectory: URL?
  /// Run input probes even when the safety guard would refuse (never while locked).
  public var allowUnfocused = false
  /// TCP port of the agent's LAN listener.
  public var listenerPort: Int = 47_821

  public init() {}
}

/// One probe result, written as one JSON object (`{probe, mac, macos, ok, evidence, needs_human,
/// notes}` plus status, items and findings).
public struct ProbeReport {
  public let probe: String
  /// The spike items this probe answers: "1" to "10" for deskhand-r-waw0, "7t13-a" and so on for
  /// the questions noted on deskhand-7t13, "add-…" for the plan's spike additions.
  public var items: [String]
  public var status: ProbeStatus = .measured
  public var needsHuman = false
  public var blockedOn: [Permission] = []
  /// Short human-readable conclusions for summary.md.
  public var findings: [String] = []
  public var notes: [String] = []
  public private(set) var evidence: [(String, JSON)] = []
  private let startedMono = Clock.monoMs()
  private let startedAt = Clock.iso()

  public init(_ probe: String, items: [String]) {
    self.probe = probe
    self.items = items
  }

  public mutating func set(_ key: String, _ value: JSON) {
    if let index = evidence.firstIndex(where: { $0.0 == key }) {
      evidence[index] = (key, value)
    } else {
      evidence.append((key, value))
    }
  }

  public mutating func finding(_ text: String) { findings.append(text) }
  public mutating func note(_ text: String) { notes.append(text) }

  public mutating func block(on permission: Permission, _ why: String) {
    if !blockedOn.contains(permission) { blockedOn.append(permission) }
    if status == .measured { status = .blockedOnPermission }
    notes.append("blocked on \(permission.rawValue): \(why)")
  }

  public mutating func skip(_ why: String) {
    status = .skipped
    notes.append("skipped: \(why)")
  }

  public mutating func fail(_ why: String) {
    status = .error
    notes.append("error: \(why)")
  }

  public func json(context: JSON) -> JSON {
    .obj([
      ("probe", .string(probe)),
      ("mac", .string(Host.macName)),
      ("macos", .string(Host.macOSVersion)),
      ("ok", .bool(status == .measured)),
      ("status", .string(status.rawValue)),
      ("needs_human", .bool(needsHuman)),
      ("items", .strings(items)),
      ("blocked_on", .strings(blockedOn.map(\.rawValue))),
      ("findings", .strings(findings)),
      ("evidence", .obj(evidence)),
      ("notes", .strings(notes)),
      ("context", context),
      ("started_at", .string(startedAt)),
      ("duration_ms", .int(Int(Clock.monoMs() - startedMono))),
    ])
  }
}

/// A named probe. `automatic` probes run in `probe all-automatic` without a person.
public struct ProbeSpec {
  public let name: String
  public let items: [String]
  public let automatic: Bool
  public let summary: String
  public let run: (ProbeOptions) async -> ProbeReport

  public init(
    name: String, items: [String], automatic: Bool = true, summary: String,
    run: @escaping (ProbeOptions) async -> ProbeReport
  ) {
    self.name = name
    self.items = items
    self.automatic = automatic
    self.summary = summary
    self.run = run
  }
}
