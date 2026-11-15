import Foundation

/// Runs harness commands somewhere: in the installed LaunchAgent (the context deskhand v0 runs
/// in, with deskhand's own TCC grants) or in this process.
public protocol Executor {
  var label: String { get }
  func call(_ words: [String]) async -> [JSON]
}

/// Talks to the LaunchAgent over its control socket.
public struct AgentExecutor: Executor {
  public let label = "launch_agent"

  public init() {}

  public func call(_ words: [String]) async -> [JSON] {
    let box = LineBox()
    let error = await ControlClient.call(words) { line in box.append(line) }
    if let error { return [.obj([("error", .string(error))])] }
    return box.lines.map { JSON.parse($0) ?? .string($0) }
  }

  private nonisolated final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
  }
}

/// Runs commands in this process (the terminal's TCC grants when started from a terminal).
public struct InProcessExecutor: Executor {
  public let label = "in_process"
  private let dispatch: @MainActor ([String], @escaping (JSON) -> Void) async -> Void

  public init(dispatch: @escaping @MainActor ([String], @escaping (JSON) -> Void) async -> Void) {
    self.dispatch = dispatch
  }

  public func call(_ words: [String]) async -> [JSON] {
    var lines: [JSON] = []
    await dispatch(words) { lines.append($0) }
    return lines
  }
}

/// A guided trial: tells the person one action at a time and records what happened.
public struct TrialSpec {
  public let name: String
  public let items: [String]
  /// Lower runs earlier in the checklist: roughly the person's effort in minutes.
  public let effort: Int
  public let summary: String
  /// What the person will do, in one line.
  public let humanActions: String
  public let run: (TrialEnv) async -> Void

  public init(
    name: String, items: [String], effort: Int, summary: String, humanActions: String,
    run: @escaping (TrialEnv) async -> Void
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
public final class TrialEnv {
  public let name: String
  public let executor: Executor
  public let count: Int
  public let options: [String: String]
  public var report: ProbeReport
  private let file: URL?
  private var attempts: [JSON] = []
  private var answers: [(String, JSON)] = []

  public init(
    spec: TrialSpec, executor: Executor, outDirectory: URL?, count: Int,
    options: [String: String]
  ) {
    name = spec.name
    self.executor = executor
    self.count = count
    self.options = options
    report = ProbeReport("trial-\(spec.name)", items: spec.items)
    if let outDirectory {
      let trials = outDirectory.appendingPathComponent("trials")
      try? FileManager.default.createDirectory(at: trials, withIntermediateDirectories: true)
      file = trials.appendingPathComponent(Self.fileStem(spec.name, options) + ".json")
    } else {
      file = nil
    }
  }

  /// `lock` with `--path shortcut` records to `trials/lock-shortcut.json`.
  public static func fileStem(_ name: String, _ options: [String: String]) -> String {
    options["path"].map { "\(name)-\($0)" } ?? name
  }

  // MARK: Talking to the person

  public func say(_ text: String) {
    print(text)
    fflush(stdout)
  }

  public func step(_ text: String) {
    say("\n>>> \(text)")
  }

  /// Reads one line from the terminal without blocking the run loop. `nil` at end of input.
  public func readLine() async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(returning: Swift.readLine()) }
    }
  }

  /// Asks a question and records the answer under `key`. Returns the lowercased first letter
  /// of the answer for y/n questions, or the whole answer otherwise.
  @discardableResult
  public func ask(_ key: String, _ question: String, choices: [String] = ["y", "n"]) async
    -> String
  {
    while true {
      say("??? \(question) [\(choices.joined(separator: "/"))]")
      guard let line = await readLine() else {
        answers.append((key, .null))
        return ""
      }
      let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
      if choices.isEmpty || choices.contains(answer) {
        answers.append((key, .string(answer)))
        save()
        return answer
      }
      if let first = answer.first.map(String.init), choices.contains(first) {
        answers.append((key, .string(first)))
        save()
        return first
      }
    }
  }

  public func waitEnter(_ text: String) async {
    say(">>> \(text)  (press Enter)")
    _ = await readLine()
  }

  // MARK: Harness calls

  public func call(_ words: [String]) async -> [JSON] {
    await executor.call(words)
  }

  public func sample() async -> JSON {
    await call(["sample"]).last.orNull
  }

  public func act(_ words: String...) async -> JSON {
    await call(["act"] + words).last.orNull
  }

  /// Polls `sample` every `everyMs` until `until` says done or `timeoutMs` passes. Returns the
  /// samples taken.
  public func poll(
    everyMs: Int, timeoutMs: Int, until: (JSON) -> Bool = { _ in false }
  ) async -> [JSON] {
    var samples: [JSON] = []
    let deadline = Clock.monoMs() + Double(timeoutMs)
    while Clock.monoMs() < deadline {
      let sample = await sample()
      samples.append(sample)
      if until(sample) { break }
      await Clock.sleep(ms: everyMs)
    }
    return samples
  }

  // MARK: Recording

  public func record(_ attempt: JSON) {
    attempts.append(attempt)
    save()
  }

  public func save(final: Bool = false) {
    report.set("executor", .string(executor.label))
    report.set("answers", .obj(answers))
    report.set("attempts", .array(attempts))
    report.set("complete", .bool(final))
    report.needsHuman = !final
    guard let file else { return }
    let text = report.json(context: RunContext.json).pretty()
    try? text.write(to: file, atomically: true, encoding: .utf8)
  }

  public func finish() {
    save(final: true)
    say("\nRecorded \(attempts.count) attempt(s)\(file.map { " in \($0.path)" } ?? "").")
    for finding in report.findings { say("  - \(finding)") }
  }
}
