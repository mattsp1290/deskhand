import AppKit
import Foundation
import SpikeInput
import SpikeKit

/// deskhand-spike: the throwaway probe harness for bn request deskhand-r-waw0.
enum Main {
  static let usage = """
    usage: deskhand-spike <command> [arguments]
      agent [--interval S] [--capture-interval S] [--port N]   LaunchAgent mode
      probe <name>...|all-automatic|list [--out DIR] [--exclude-bundle-id ID]... [--save-images]
      trial <name>|list [--out DIR] [--count N] [--path P] [--in-process]
      agent-call <command words...> [--out DIR]   run a command inside the LaunchAgent
      sample | act <action> [arg] | ping | status  run one harness command here
      register | unregister | service-status      SMAppService for the bundled LaunchAgent
      summarize --dir DIR                          write DIR/summary.md
      checklist --dir DIR [--ids]                  remaining manual steps, least effort first
      agent-log [--out DIR]                        condense the LaunchAgent log
    """

  static func run(_ arguments: [String]) async -> Int32 {
    guard let command = arguments.first else {
      print(usage)
      return 2
    }
    var rest = Array(arguments.dropFirst())
    let out = take("--out", from: &rest).map { URL(fileURLWithPath: $0) }
    switch command {
    case "agent":
      await Agent.run(rest)
      return 0
    case "probe":
      await Dispatcher.run(["probe"] + rest) { line in emit(line, out: out) }
      return 0
    case "sample", "act", "ping", "status":
      await Dispatcher.run(arguments) { line in print(line.compact()) }
      return 0
    case "agent-call":
      guard !rest.isEmpty else {
        print(usage)
        return 2
      }
      let lines = await AgentExecutor().call(rest)
      for line in lines { emit(line, out: out) }
      return lines.contains { $0["error"]?.stringValue?.hasPrefix("agent not reachable") == true }
        ? 3 : 0
    case "trial":
      return await runTrial(rest, out: out)
    case "register", "unregister", "service-status":
      let (json, code) = await Register.run(command == "service-status" ? "status" : command)
      print(json.compact())
      return code
    case "summarize":
      guard let directory = take("--dir", from: &rest) else {
        print(usage)
        return 2
      }
      print(Summary.write(directory: URL(fileURLWithPath: directory)).path)
      return 0
    case "checklist":
      let directory = take("--dir", from: &rest) ?? FileManager.default.currentDirectoryPath
      Checklist.print(directory: URL(fileURLWithPath: directory), idsOnly: rest.contains("--ids"))
      return 0
    case "agent-log":
      emit(AgentLog.report().json(context: RunContext.json), out: out)
      return 0
    case InputCatalog.childCommand:
      return await InputCatalog.runChild(rest)
    case "help", "--help", "-h":
      print(usage)
      return 0
    default:
      print(usage)
      return 2
    }
  }

  /// Prints one result line; with `--out`, also writes `<out>/<probe>.json`.
  static func emit(_ line: JSON, out: URL?) {
    print(line.compact())
    fflush(stdout)
    guard let out, let name = line["probe"]?.stringValue else { return }
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try? line.pretty().write(
      to: out.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
  }

  static func take(_ flag: String, from words: inout [String]) -> String? {
    guard let index = words.firstIndex(of: flag), index + 1 < words.count else { return nil }
    let value = words[index + 1]
    words.removeSubrange(index...(index + 1))
    return value
  }

  static func runTrial(_ arguments: [String], out: URL?) async -> Int32 {
    var rest = arguments
    let count = take("--count", from: &rest).flatMap(Int.init)
    var options: [String: String] = [:]
    if let path = take("--path", from: &rest) { options["path"] = path }
    let inProcess = rest.contains("--in-process")
    rest.removeAll { $0 == "--in-process" }
    guard let name = rest.first else {
      print(usage)
      return 2
    }
    if name == "list" {
      for trial in Catalog.trials {
        print("\(trial.name) (effort \(trial.effort), items \(trial.items.joined(separator: ", "))): \(trial.summary)")
      }
      return 0
    }
    guard let spec = Catalog.trial(name) else {
      print("unknown trial \(name)")
      return 2
    }
    var executor: Executor = InProcessExecutor { words, emit in
      await Dispatcher.run(words, emit: emit)
    }
    if !inProcess {
      let agent = AgentExecutor()
      let ping = await agent.call(["ping"]).first
      if ping?["pong"]?.boolValue == true {
        executor = agent
      } else {
        print(
          "The LaunchAgent is not reachable; running in this process (TCC grants are this "
            + "terminal's). Install with scripts/install.sh to measure deskhand's own grants.")
      }
    }
    let env = TrialEnv(
      spec: spec, executor: executor, outDirectory: out, count: count ?? (name == "lock" ? 20 : 3),
      options: options)
    print("deskhand-spike trial \(name) on \(Host.macName), executor \(executor.label)")
    print("This harness never asks for, types or stores your password.")
    await spec.run(env)
    return 0
  }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
  let code = await Main.run(Array(CommandLine.arguments.dropFirst()))
  exit(code)
}
application.run()
