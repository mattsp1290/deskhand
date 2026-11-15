import Darwin
import Foundation

/// How this process was started. TCC attributes a process's requests to its responsible process,
/// so the same probe means different things from a terminal (the terminal app's grants), from
/// `open` (deskhand-spike.app's grants) and as the LaunchAgent (deskhand-spike.app's grants, in
/// the context deskhand v0 runs in).
public enum RunContext {
  public static let bundleIdentifier = "homes.birb.deskhand"
  public static let agentLabel = "homes.birb.deskhand.agent"

  public nonisolated enum LaunchedBy: String, Sendable {
    case launchAgent = "launch_agent"
    case launchServices = "launch_services"
    case terminal
  }

  public static var launchedBy: LaunchedBy {
    let env = ProcessInfo.processInfo.environment
    if env["XPC_SERVICE_NAME"] == agentLabel { return .launchAgent }
    if env["DESKHAND_SPIKE_AGENT"] == "1" { return .launchAgent }
    if getppid() == 1 { return .launchServices }
    return .terminal
  }

  /// Cached: code-signing reads are slow and the answer never changes while the process runs.
  public static let json: JSON = build()

  private static func build() -> JSON {
    let env = ProcessInfo.processInfo.environment
    let bundle = Bundle.main
    let by = launchedBy
    let attribution: String
    switch by {
    case .terminal:
      let parent = env["__CFBundleIdentifier"] ?? "unknown"
      attribution =
        "TCC attributes this process to the terminal app (\(parent)); its grants are not deskhand's"
    case .launchServices, .launchAgent:
      attribution = "TCC attributes this process to \(bundle.bundleIdentifier ?? "its own binary")"
    }
    let signature = CodeSigning.selfFacts()
    return .obj([
      ("launched_by", .string(by.rawValue)),
      ("pid", .int(Int(getpid()))),
      ("ppid", .int(Int(getppid()))),
      ("xpc_service_name", .str(env["XPC_SERVICE_NAME"])),
      ("parent_bundle_id", .str(by == .terminal ? env["__CFBundleIdentifier"] : nil)),
      ("bundle_id", .str(bundle.bundleIdentifier)),
      ("bundle_version", .str(bundle.infoDictionary?["CFBundleVersion"] as? String)),
      ("bundle_path", .string(bundle.bundlePath)),
      ("tcc_attribution", .string(attribution)),
      ("team_id", signature["team_id"].orNull),
      ("adhoc", signature["adhoc"].orNull),
      ("hardened_runtime", signature["hardened_runtime"].orNull),
      ("leaf_common_name", signature["leaf_common_name"].orNull),
      ("designated_requirement", signature["designated_requirement"].orNull),
    ])
  }
}
