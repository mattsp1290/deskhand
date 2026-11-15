import AppKit
import Foundation
import SpikeInput
import SpikeKit

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
      peer-connect ADDRESS PORT NONCE              explicit peer network helper
      peer-assess --target FILE --peer FILE [--out DIR]   offline evidence correlation
      campaign-import --dir DIR --run ID           import an isolated invocation
      summarize --dir DIR                          write DIR/summary.md
      checklist --dir DIR [--ids]                  remaining manual steps, least effort first
      agent-log [--out DIR]                        condense the LaunchAgent log
    """

  static func run(_ arguments: [String]) async -> Int32 {
    do { try NumericArguments.validate(arguments) } catch {
      print("usage error: \(error)")
      return 2
    }
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
      do {
        let lines = try await AgentExecutor(expectedProbes: Catalog.expectedProbes).call(rest)
          .reports
        var failed = false
        for line in lines { if !emit(line, out: out) { failed = true } }
        return failed ? 3 : 0
      } catch let failure as CommandFailure {
        for line in failure.partialReports { _ = emit(line, out: out) }
        print(
          JSON.obj([("error", .string(failure.reason)), ("raw_lines", .strings(failure.rawLines))])
            .compact())
        return 3
      } catch {
        print("agent command failed: \(error)")
        return 3
      }
    case "trial":
      return await runTrial(rest, out: out)
    case "register", "unregister", "service-status":
      let (json, code) = await Register.run(command == "service-status" ? "status" : command)
      print(json.compact())
      return code
    case "peer-connect":
      guard rest.count == 3, let port = Int(rest[1]), (1...65534).contains(port),
        UUID(uuidString: rest[2]) != nil
      else { return 2 }
      let host = rest[0]
      let result = await Task.detached { Net.connect(host: host, port: port, timeoutMs: 5000) }
        .value
        .setting("source_host", .string(Host.macName)).setting("expected_nonce", .string(rest[2]))
      print(result.compact())
      return result["connected"]?.boolValue == true ? 0 : 1
    case "peer-assess":
      guard let targetFile = take("--target", from: &rest),
        let peerFile = take("--peer", from: &rest), rest.isEmpty
      else { return 2 }
      do {
        let target = try String(contentsOfFile: targetFile, encoding: .utf8)
        let peer = try String(contentsOfFile: peerFile, encoding: .utf8)
        let targetJSON = JSON.parse(target) ?? .null
        let peerJSON = JSON.parse(peer) ?? .null
        var report = ProbeReport("peer-listener", items: ["9"])
        report.set("target", targetJSON)
        report.set("peer", peerJSON)
        let valid = PeerEvidence.correlated(target: targetJSON, peer: peerJSON)
        report.status = valid ? .measured : .inconclusive
        report.finding(
          valid
            ? "Distinct-host connection matched the target nonce and accepted source endpoint."
            : "Cross-host listener evidence is pending or failed correlation.")
        return emit(report.json(context: targetJSON["context"].orNull), out: out) && valid ? 0 : 1
      } catch {
        print("peer assessment failed: \(error)")
        return 1
      }
    case "campaign-import":
      guard let directory = take("--dir", from: &rest), let run = take("--run", from: &rest),
        rest.isEmpty
      else { return 2 }
      do {
        try Campaign.importRun(run, into: URL(fileURLWithPath: directory))
        return 0
      } catch {
        print("campaign import failed: \(error)")
        return 1
      }
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
    if let path = options["path"],
      name != "lock" || !LockTrial.paths.contains(where: { $0.name == path })
    {
      print("invalid path for trial \(name)")
      return 2
    }
    let sessionToken = inProcess ? nil : UUID().uuidString
    let executor: Executor =
      sessionToken.map {
        AgentExecutor(sessionToken: $0, expectedProbes: Catalog.expectedProbes) as Executor
      } ?? InProcessExecutor { words, emit in await Dispatcher.run(words, emit: emit) }
    let management = AgentExecutor(expectedProbes: Catalog.expectedProbes)
    let env = TrialEnv(
      spec: spec, executor: executor, outDirectory: out,
      count: count ?? (name == "lock" ? 20 : 3), options: options)
    if inProcess { env.executorContext = RunContext.json }
    var failed = false
    do {
      try env.save()
      if let sessionToken {
        _ = try await management.call(["session", "begin", sessionToken])
        env.executorContext = try await executor.call(["ping"]).reports.first?["context"] ?? .null
      }
      if name == "drag-owner" || name == "exclusion" {
        env.report.set("measurement_context", RunContext.json)
        env.report.note("Includes driver-only measurement. Excluded from LaunchAgent conclusions.")
      }
      print("deskhand-spike trial \(name) on \(Host.macName), executor \(executor.label)")
      print("This harness never asks for, types or stores your password.")
      try await spec.run(env)
      failed = env.report.json(context: .null)["evidence"]?["complete"]?.boolValue != true
    } catch {
      failed = true
      env.abort(error)
      print("trial failed: \(error)")
    }
    if let sessionToken {
      do { _ = try await management.call(["session", "end", sessionToken]) } catch {
        failed = true
        env.abort(error)
        print("session release failed: \(error)")
      }
    }
    return failed ? 1 : 0
  }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
  let code = await Main.run(Array(CommandLine.arguments.dropFirst()))
  exit(code)
}
application.run()
