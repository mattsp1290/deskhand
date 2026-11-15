import AppKit
import Foundation
import SpikeInput
import SpikeKit

/// deskhand-spike: the throwaway probe harness for bn request deskhand-r-waw0.
enum Main {
  static let usage = """
    usage: deskhand-spike <command> [arguments]
      selfcheck                                    deterministic checks only
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
    case "selfcheck":
      do {
        print(try SelfCheck.run().compact())
        return 0
      } catch {
        print("selfcheck failed: \(error)")
        return 1
      }
    case "agent":
      await Agent.run(rest)
      return 0
    case "probe":
      var failed = false
      await Dispatcher.run(["probe"] + rest) { line in
        if !emit(line, out: out) || line["error"] != nil { failed = true }
      }
      return failed ? 1 : 0
    case "sample", "act", "ping", "status":
      await Dispatcher.run(arguments) { line in print(line.compact()) }
      return 0
    case "agent-call":
      guard !rest.isEmpty else {
        print(usage)
        return 2
      }
      let lines = await AgentExecutor().call(rest)
      var failed = false
      for line in lines {
        if !emit(line, out: out) || line["error"] != nil { failed = true }
      }
      return failed ? 3 : 0
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
      do {
        print(try Summary.write(directory: URL(fileURLWithPath: directory)).path)
        return 0
      } catch {
        print("summary write failed: \(error)")
        return 1
      }
    case "checklist":
      let directory = take("--dir", from: &rest) ?? FileManager.default.currentDirectoryPath
      Checklist.print(directory: URL(fileURLWithPath: directory), idsOnly: rest.contains("--ids"))
      return 0
    case "agent-log":
      return emit(AgentLog.report().json(context: RunContext.json), out: out) ? 0 : 1
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
  @discardableResult
  static func emit(_ line: JSON, out: URL?) -> Bool {
    print(line.compact())
    fflush(stdout)
    guard let out, let name = line["probe"]?.stringValue else { return true }
    do {
      try EvidenceWriter.write(line.pretty(), to: out.appendingPathComponent("\(name).json"))
      return true
    } catch {
      FileHandle.standardError.write(Data(("evidence write failed: \(error)\n").utf8))
      return false
    }
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
        print(
          "\(trial.name) (effort \(trial.effort), items \(trial.items.joined(separator: ", "))): \(trial.summary)"
        )
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
    var executorContext = RunContext.json
    var sessionToken: String?
    if !inProcess {
      let token = UUID().uuidString
      let acquired = await AgentExecutor().call(["session", "begin", token]).first
      guard acquired?["session"]?.boolValue == true else {
        print("Cannot acquire the LaunchAgent measurement session.")
        return 3
      }
      sessionToken = token
      let agent = AgentExecutor(sessionToken: token)
      let ping = await agent.call(["ping"]).first
      if ping?["pong"]?.boolValue == true {
        executor = agent
        executorContext = ping?["context"] ?? .null
      } else {
        _ = await AgentExecutor().call(["session", "end", token])
        print(
          "The LaunchAgent is required. Install with spike/scripts/install.sh or explicitly use --in-process for diagnostics."
        )
        return 3
      }
    }
    let env = TrialEnv(
      spec: spec, executor: executor, outDirectory: out, count: count ?? (name == "lock" ? 20 : 3),
      options: options)
    env.executorContext = executorContext
    if name == "drag-owner" || name == "exclusion" {
      env.report.set("measurement_context", RunContext.json)
      env.report.note("Includes driver-only measurement. Excluded from LaunchAgent conclusions.")
    }
    print("deskhand-spike trial \(name) on \(Host.macName), executor \(executor.label)")
    print("This harness never asks for, types or stores your password.")
    await spec.run(env)
    if let sessionToken {
      let released = await AgentExecutor().call(["session", "end", sessionToken]).first
      guard released?["session"]?.boolValue == true else { return 3 }
    }
    return env.persistenceError == nil && env.report.status != .error ? 0 : 1
  }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
  let code = await Main.run(Array(CommandLine.arguments.dropFirst()))
  exit(code)
}
application.run()
