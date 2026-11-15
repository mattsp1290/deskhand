import Foundation

public nonisolated enum TrialAbort: Error {
  case inputClosed
  case failed(String)
}

public nonisolated struct CommandReply {
  public let reports: [JSON]
  public init(_ reports: [JSON]) { self.reports = reports }
}

public nonisolated struct CommandFailure: Error {
  public let reason: String
  public let partialReports: [JSON]
  public let rawLines: [String]
  public init(_ reason: String, reports: [JSON] = [], rawLines: [String] = []) {
    self.reason = reason
    self.partialReports = reports
    self.rawLines = rawLines
  }
}

public nonisolated enum CommandProtocol {
  public static func result(_ report: JSON, id: String) -> JSON {
    .obj([("id", .string(id)), ("result", report)])
  }

  public static func completion(id: String, count: Int, success: Bool) -> JSON {
    .obj([
      ("id", .string(id)), ("complete", .bool(true)), ("count", .int(count)),
      ("success", .bool(success)),
    ])
  }

  public static func validate(
    _ lines: [String], id: String, expectedProbes: [String]?,
    transportError: String? = nil
  ) throws -> CommandReply {
    var reports: [JSON] = []
    var completed = false
    func failure(_ reason: String) -> CommandFailure {
      CommandFailure(reason, reports: reports, rawLines: lines)
    }
    for line in lines {
      guard !completed, let frame = JSON.parse(line), frame.members != nil,
        frame["id"]?.stringValue == id
      else { throw failure("invalid reply frame or request ID") }
      if let report = frame["result"], report.members != nil {
        reports.append(report)
      } else {
        guard frame["complete"]?.boolValue == true,
          frame["count"]?.intValue == reports.count,
          frame["success"]?.boolValue == true
        else { throw failure("unsuccessful or mismatched completion") }
        completed = true
      }
    }
    if let transportError { throw failure(transportError) }
    guard completed, !reports.isEmpty else { throw failure("missing command completion") }
    guard !reports.contains(where: { $0["error"] != nil || $0["status"]?.stringValue == "error" })
    else {
      throw failure("command result reports failure")
    }
    if let expectedProbes {
      guard reports.compactMap({ $0["probe"]?.stringValue }) == expectedProbes else {
        throw failure("probe names do not match the requested catalog operation")
      }
    } else if reports.count != 1 {
      throw failure("expected one command result")
    }
    return CommandReply(reports)
  }
}

public protocol Executor {
  var label: String { get }
  func call(_ words: [String]) async throws -> CommandReply
  func restart(previousContext: JSON) async throws -> JSON
}

extension Executor {
  public func restart(previousContext: JSON) async throws -> JSON {
    throw TrialAbort.failed("this executor cannot restart")
  }
}

public struct AgentExecutor: Executor {
  public let label = "launch_agent"
  private let sessionToken: String?
  private let expectedProbes: ([String]) -> [String]?
  private let transport: ([String], Int32, @escaping @Sendable (String) -> Void) async -> String?
  private let restartAgent: () async throws -> Void
  private let restartWaitMs: Double

  public init(
    sessionToken: String? = nil, expectedProbes: @escaping ([String]) -> [String]?,
    transport: @escaping ([String], Int32, @escaping @Sendable (String) -> Void) async -> String? =
      {
        await ControlClient.call($0, timeoutMs: $1, onLine: $2)
      }, restartWaitMs: Double = 15_000,
    restartAgent: @escaping () async throws -> Void = {
      let result = await Shell.runAsync(
        "/bin/launchctl",
        ["kickstart", "-k", "gui/\(getuid())/\(RunContext.agentLabel)"], timeout: 15)
      guard result.status == 0, !result.timedOut else {
        throw TrialAbort.failed("agent restart failed: \(result.json.compact())")
      }
    }
  ) {
    self.sessionToken = sessionToken
    self.expectedProbes = expectedProbes
    self.transport = transport
    self.restartAgent = restartAgent
    self.restartWaitMs = restartWaitMs
  }

  public func call(_ words: [String]) async throws -> CommandReply {
    let box = LineBox()
    let id = UUID().uuidString
    let request = sessionToken.map { ["session", $0] + words } ?? words
    let error = await transport(["request", id] + request, words == ["ping"] ? 1000 : 120_000) {
      line in box.append(line)
    }
    return try CommandProtocol.validate(
      box.lines, id: id, expectedProbes: expectedProbes(words), transportError: error)
  }

  public func restart(previousContext: JSON) async throws -> JSON {
    guard let sessionToken else { throw TrialAbort.failed("restart requires an owned session") }
    try await restartAgent()
    let management = AgentExecutor(expectedProbes: expectedProbes, transport: transport)
    let deadline = Clock.monoMs() + restartWaitMs
    while Clock.monoMs() < deadline {
      if let reply = try? await management.call(["ping"]),
        let context = reply.reports.first?["context"],
        context["process_instance"] != previousContext["process_instance"]
      {
        try SessionIdentity.verifyReplacement(previous: previousContext, replacement: context)
        _ = try await management.call(["session", "resume", sessionToken])
        return context
      }
      await Clock.sleep(ms: 250)
    }
    throw TrialAbort.failed("replacement agent did not become ready; session remains reserved")
  }

  private nonisolated final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
  }
}

public struct InProcessExecutor: Executor {
  public let label = "in_process"
  private let dispatch: @MainActor ([String], @escaping (JSON) -> Void) async -> Void

  public init(dispatch: @escaping @MainActor ([String], @escaping (JSON) -> Void) async -> Void) {
    self.dispatch = dispatch
  }

  public func call(_ words: [String]) async throws -> CommandReply {
    var lines: [JSON] = []
    await dispatch(words) { lines.append($0) }
    guard !lines.isEmpty,
      !lines.contains(where: { $0["error"] != nil || $0["status"]?.stringValue == "error" })
    else {
      throw CommandFailure("command failed", reports: lines)
    }
    return CommandReply(lines)
  }
}

/// A guided trial: tells the person one action at a time and records what happened.
@MainActor public struct TrialSpec {
  public let name: String
  public let items: [String]
  /// Lower runs earlier in the checklist: roughly the person's effort in minutes.
  public let effort: Int
  public let summary: String
  /// What the person will do, in one line.
  public let humanActions: String
  public let run: @MainActor (TrialEnv) async throws -> Void

  public init(
    name: String, items: [String], effort: Int, summary: String, humanActions: String,
    run: @escaping @MainActor (TrialEnv) async throws -> Void
  ) {
    self.name = name
    self.items = items
    self.effort = effort
    self.summary = summary
    self.humanActions = humanActions
    self.run = run
  }
}

/// What a trial sees: prompts on the terminal, the executor, and its result file.
@MainActor public final class TrialEnv {
  public let name: String
  public let executor: Executor
  public let count: Int
  public let options: [String: String]
  public var report: ProbeReport
  public private(set) var persistenceError: String?
  public var executorContext: JSON = .null
  private let input: () async -> String?
  private let file: URL?
  private var attempts: [JSON] = []
  private var answers: [(String, JSON)] = []

  public init(
    spec: TrialSpec, executor: Executor, outDirectory: URL?, count: Int,
    options: [String: String], input: @escaping () async -> String? = TrialEnv.terminalLine
  ) {
    self.input = input
    name = spec.name
    self.executor = executor
    self.count = count
    self.options = options
    report = ProbeReport("trial-\(spec.name)", items: spec.items)
    if let outDirectory {
      let trials = outDirectory.appendingPathComponent("trials")
      file = trials.appendingPathComponent(Self.fileStem(spec.name, options) + ".json")
    } else {
      file = nil
    }
  }

  /// `lock` with `--path shortcut` records to `trials/lock-shortcut.json`.
  public static func fileStem(_ name: String, _ options: [String: String]) -> String {
    options["path"].map { "\(name)-\($0)" } ?? name
  }

  public func say(_ text: String) {
    print(text)
    fflush(stdout)
  }

  public func step(_ text: String) {
    say("\n>>> \(text)")
  }

  /// Reads one line from the terminal without blocking the run loop. `nil` at end of input.
  public static func terminalLine() async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(returning: Swift.readLine()) }
    }
  }

  /// Asks a question and records the answer under `key`. Returns the lowercased first letter
  /// of the answer for y/n questions, or the whole answer otherwise.
  @discardableResult
  public func ask(_ key: String, _ question: String, choices: [String] = ["y", "n"]) async throws
    -> String
  {
    while true {
      say("??? \(question) [\(choices.joined(separator: "/"))]")
      guard let line = await input() else {
        answers.append((key, .null))
        try save()
        throw TrialAbort.inputClosed
      }
      let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
      if choices.isEmpty || choices.contains(answer) {
        answers.append((key, .string(answer)))
        try save()
        return answer
      }
      if let first = answer.first.map(String.init), choices.contains(first) {
        answers.append((key, .string(first)))
        try save()
        return first
      }
    }
  }

  public func waitEnter(_ text: String) async throws {
    say(">>> \(text)  (press Enter)")
    guard await input() != nil else {
      answers.append(("readiness", .null))
      try save()
      throw TrialAbort.inputClosed
    }
  }

  public func call(_ words: [String]) async throws -> [JSON] {
    guard persistenceError == nil else { throw TrialAbort.failed("evidence persistence failed") }
    do {
      let results = try await executor.call(words).reports
      for result in results where report.status == .measured {
        switch result["status"]?.stringValue {
        case "blocked_on_permission": report.status = .blockedOnPermission
        case "inconclusive", "skipped": report.status = .inconclusive
        default: break
        }
      }
      return results
    } catch let failure as CommandFailure {
      report.set(
        "command_failure",
        .obj([
          ("command", .strings(words)), ("reason", .string(failure.reason)),
          ("partial_reports", .array(failure.partialReports)),
          ("raw_lines", .strings(failure.rawLines)),
        ]))
      report.fail(failure.reason)
      try save()
      throw failure
    }
  }

  public func restartExecutor() async throws {
    executorContext = try await executor.restart(previousContext: executorContext)
    try record(.obj([("step", .string("agent_restart")), ("context", executorContext)]))
  }

  public func abort(_ error: any Error) {
    report.fail("trial aborted: \(error)")
    do { try save() } catch { say("Could not persist aborted trial: \(error)") }
  }

  public func sample() async throws -> JSON {
    try await call(["sample"]).last.orNull
  }

  public func act(_ words: String...) async throws -> JSON {
    try await call(["act"] + words).last.orNull
  }

  /// Polls `sample` every `everyMs` until `until` says done or `timeoutMs` passes. Returns the
  /// samples taken.
  public func poll(
    everyMs: Int, timeoutMs: Int, until: (JSON) -> Bool = { _ in false }
  ) async throws -> [JSON] {
    var samples: [JSON] = []
    let deadline = Clock.monoMs() + Double(timeoutMs)
    while Clock.monoMs() < deadline {
      let sample = try await sample()
      samples.append(sample)
      if until(sample) { break }
      await Clock.sleep(ms: everyMs)
    }
    return samples
  }

  public func record(_ attempt: JSON) throws {
    attempts.append(attempt)
    try save()
  }

  public func save(final: Bool = false) throws {
    report.set("executor", .string(executor.label))
    report.set("executor_context", executorContext)
    report.set("answers", .obj(answers))
    report.set("attempts", .array(attempts))
    report.set("complete", .bool(final && persistenceError == nil && report.status == .measured))
    report.needsHuman = !final
    guard let file else { return }
    let text = report.json(context: RunContext.json).pretty()
    do {
      try EvidenceWriter.write(text, to: file)
    } catch {
      report.fail("evidence persistence failed")
      report.set("complete", .bool(false))
      persistenceError = "evidence write failed at \(file.path): \(error)"
      FileHandle.standardError.write(Data((persistenceError! + "\n").utf8))
      throw error
    }
  }

  public func finish() throws {
    if attempts.isEmpty && report.status == .measured {
      report.status = .inconclusive
      report.note("No attempts were recorded.")
    }
    try save(final: true)
    guard persistenceError == nil, report.status != .error else {
      say("Trial incomplete because execution or evidence persistence failed.")
      return
    }
    say("\nRecorded \(attempts.count) attempt(s)\(file.map { " in \($0.path)" } ?? "").")
    for finding in report.findings { say("  - \(finding)") }
  }
}
