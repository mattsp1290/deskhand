import Foundation
import Testing

@testable import SpikeKit

@Test @MainActor func closedInputStopsEveryLaterEffect() async throws {
  for ask in [false, true] {
    var effects = 0
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let spec = TrialSpec(
      name: "closed", items: [], effort: 0, summary: "", humanActions: "",
      run: { env in
        if ask {
          _ = try await env.ask("answer", "Ready?")
        } else {
          try await env.waitEnter("Ready")
        }
        effects += 1
        _ = try await env.act("never")
        try env.finish()
      })
    let env = TrialEnv(
      spec: spec,
      executor: InProcessExecutor { _, emit in
        effects += 1
        emit(.obj([("effect", .bool(true))]))
      }, outDirectory: directory, count: 1, options: [:], input: { nil })
    do {
      try await spec.run(env)
      Issue.record("EOF did not throw")
    } catch { env.abort(error) }
    #expect(effects == 0)
    let result = try #require(
      JSON.parse(
        String(contentsOf: directory.appendingPathComponent("trials/closed.json"), encoding: .utf8))
    )
    #expect(result["status"] == .string("error"))
    #expect(result["evidence"]?["complete"] == .bool(false))
  }
}

@Test func completeReplyContractRejectsAdversarialReplies() throws {
  let a = CommandProtocol.result(.obj([("probe", .string("a"))]), id: "request").compact()
  let b = CommandProtocol.result(.obj([("probe", .string("b"))]), id: "request").compact()
  let done = CommandProtocol.completion(id: "request", count: 2, success: true).compact()
  #expect(
    try CommandProtocol.validate([a, b, done], id: "request", expectedProbes: ["a", "b"]).reports
      .count == 2)
  let failures: [[String]] = [
    [], ["garbage"], ["[]"], [a], [a, b], [a, done], [a, b, done, done], [a, b, done, a],
    [a, b, CommandProtocol.completion(id: "wrong", count: 2, success: true).compact()],
    [a, b, CommandProtocol.completion(id: "request", count: 2, success: false).compact()],
  ]
  for lines in failures {
    #expect(throws: CommandFailure.self) {
      try CommandProtocol.validate(lines, id: "request", expectedProbes: ["a", "b"])
    }
  }
  #expect(throws: CommandFailure.self) {
    try CommandProtocol.validate([a, b, done], id: "request", expectedProbes: ["a", "c"])
  }
  do { _ = try CommandProtocol.validate([a], id: "request", expectedProbes: ["a", "b"]) } catch let
    failure as CommandFailure
  {
    #expect(failure.partialReports.count == 1)
    #expect(failure.rawLines == [a])
  }
}

@Test @MainActor func durableSessionRestoresSuspendedAndRequiresSameArtifact() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("claim.json")
  let token = UUID().uuidString
  let first = MeasurementSession(file: file, artifactID: "artifact-a")
  #expect(first.begin(token))
  let replacement = MeasurementSession(file: file, artifactID: "artifact-a")
  #expect(!replacement.isIdle)
  #expect(!replacement.enter(nil))
  #expect(!replacement.enter(token))
  #expect(!replacement.resume(UUID().uuidString))
  #expect(replacement.resume(token))
  #expect(replacement.enter(token))
  replacement.leave()
  let mismatch = MeasurementSession(file: file, artifactID: "artifact-b")
  #expect(!mismatch.end(token))
  #expect(!mismatch.resume(token))
  #expect(!mismatch.isIdle)
  #expect(replacement.end(token))
  #expect(MeasurementSession(file: file, artifactID: "artifact-a").isIdle)
  try "malformed".write(to: file, atomically: true, encoding: .utf8)
  let malformed = MeasurementSession(file: file, artifactID: "artifact-a")
  #expect(!malformed.isIdle)
  #expect(!malformed.begin(token))
  #expect(!malformed.enter(nil))
}

@Test func replacementIdentityRequiresChangedProcessAndSameArtifact() throws {
  func context(_ pid: Int, _ instance: String, _ hash: String) -> JSON {
    .obj([
      ("pid", .int(pid)), ("process_instance", .string(instance)), ("cdhash", .string(hash)),
      ("build_receipt", .obj([("source", .string("commit"))])),
      ("bundle_path", .string("/Applications/Test.app")),
      ("launched_by", .string("launch_agent")),
    ])
  }
  let original = context(1, "old", "hash")
  try SessionIdentity.verifyReplacement(previous: original, replacement: context(2, "new", "hash"))
  for replacement in [
    original, context(1, "new", "hash"), context(2, "old", "hash"), context(2, "new", "changed"),
  ] {
    #expect(throws: TrialAbort.self) {
      try SessionIdentity.verifyReplacement(previous: original, replacement: replacement)
    }
  }
}

@Test func idleRequiresDeliveredFiniteBaselineAndTiming() {
  #expect(MeasurementAnalysis.idle(delivered: true, before: 2, after: 0.1, elapsed: 0.2) == .reset)
  #expect(
    MeasurementAnalysis.idle(delivered: true, before: 2, after: 2.2, elapsed: 0.2) == .unchanged)
  for (delivered, before, after, elapsed): (Bool, Double?, Double?, Double) in [
    (true, 0.2, 0.1, 0.2), (false, 2, 0.1, 0.2), (true, nil, 0.1, 0.2), (true, 2, nil, 0.2),
    (true, .infinity, 0.1, 0.2), (true, 2, 0.1, 2), (true, 2, 1, 0.2),
  ] {
    if case .inconclusive = MeasurementAnalysis.idle(
      delivered: delivered, before: before, after: after, elapsed: elapsed)
    {
    } else {
      Issue.record("invalid idle row classified")
    }
  }
}

@Test func wakeRequiresSuccessfulSleepAndImmediateAsleepState() {
  func sample(_ asleep: Bool) -> JSON {
    .obj([("displays", .array([.obj([("main", .bool(true)), ("asleep", .bool(asleep))])]))])
  }
  for (success, final, before) in [
    (false, true, true), (true, false, false), (true, true, false), (true, false, true),
  ] {
    let result = MeasurementAnalysis.wake(
      sleepSucceeded: success, finalPoll: sample(final), beforeAssertion: sample(before),
      awakeAfter: true)
    #expect(result["valid"] == .bool(false))
    #expect(result["woke"] == .bool(false))
  }
  #expect(
    MeasurementAnalysis.wake(
      sleepSucceeded: true, finalPoll: sample(true), beforeAssertion: sample(true), awakeAfter: true
    )["woke"] == .bool(true))
}

@Test func lockScoresInitialFalseNeverTrueAndUnknownOnlyInsideReference() {
  let samples: [JSON] = (0..<6).map { index in
    .obj([
      (
        "lock",
        .obj([
          ("delayed", .bool(index >= 3 && index < 5)), ("never", .bool(false)),
          ("unknown", .null), ("correct", .bool(index < 5)),
        ])
      )
    ])
  }
  let result = MeasurementAnalysis.lock(
    samples, t0: 0, reference: LockReference(provenance: .independent, lockedIndices: Set(0..<5)))
  #expect(result["delayed"]?["false_unlocked_samples"] == .int(3))
  #expect(result["never"]?["false_unlocked_samples"] == .int(5))
  #expect(result["unknown"]?["unknown_samples"] == .int(5))
  #expect(result["correct"]?["false_unlocked_samples"] == .int(0))
  let agreement = MeasurementAnalysis.lock(
    samples, t0: 0,
    reference: LockReference(provenance: .candidateAgreement, lockedIndices: Set(0..<5)))
  #expect(agreement["correct"]?["safety_conclusion"] == .string("inconclusive"))
}

@Test func numericBoundariesRejectMalformedAndOverflowingValues() throws {
  for words in [
    ["--count", "0"], ["--count", "-1"], ["--count", "x"], ["--count"],
    ["--port", "65535"], ["--listener-port", "0"], ["--interval", String(Int.max)],
    ["--capture-interval", "0"],
  ] {
    #expect(throws: TrialAbort.self) { try NumericArguments.validate(words) }
  }
  try NumericArguments.validate(["--count", "1", "--port", "65534", "--interval", "30"])
}

@Test @MainActor func captureManifestNeverSelectsStaleCacheImages() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let old = root.appendingPathComponent("display-excluded-old.png")
  try Data([1]).write(to: old)
  var manifest = CaptureManifest()
  let requested = JSON.obj([("bundle_id", .string("selected.app")), ("display_id", .int(1))])
  manifest.requested = [requested]
  #expect(throws: TrialAbort.self) {
    try CaptureManifest.previews(manifest.json, selected: ["selected.app"], root: root)
  }
  manifest.savedImages = [requested.setting("path", .string(old.path))]
  #expect(throws: TrialAbort.self) {
    try CaptureManifest.previews(manifest.json, selected: ["selected.app"], root: root)
  }
  let directory = root.appendingPathComponent(manifest.captureID)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let current = directory.appendingPathComponent("display-1.png")
  try Data([2]).write(to: current)
  manifest.savedImages = [requested.setting("path", .string(current.path))]
  #expect(
    try CaptureManifest.previews(manifest.json, selected: ["selected.app"], root: root) == [
      current.path
    ])
  #expect(FileManager.default.fileExists(atPath: old.path))
  #expect(throws: TrialAbort.self) {
    try CaptureManifest.previews(manifest.json, selected: [], root: root)
  }
}

@Test func peerEvidenceRequiresNonceAndDistinctMatchingEndpoints() {
  let nonce = UUID().uuidString
  let target = JSON.obj([
    ("nonce", .string(nonce)), ("address", .string("192.0.2.1")), ("port", .int(47821)),
    ("target_host", .string("target")),
    (
      "accepted",
      .array([
        .obj([
          ("nonce", .string(nonce)),
          ("peer", .string("192.0.2.2:12345")), ("t", .obj([("mono_ms", .double(1))])),
        ])
      ])
    ),
  ])
  let peer = JSON.obj([
    ("source_host", .string("peer")), ("local_address", .string("192.0.2.2")),
    ("local_port", .int(12345)), ("host", .string("192.0.2.1")), ("port", .int(47821)),
    ("connected", .bool(true)), ("expected_nonce", .string(nonce)),
    (
      "greeting",
      .string(JSON.obj([("nonce", .string(nonce)), ("target_host", .string("target"))]).compact())
    ),
  ])
  #expect(PeerEvidence.correlated(target: target, peer: peer))
  for invalid in [
    peer.setting("source_host", .string("target")),
    peer.setting("local_address", .string("192.0.2.1")),
    peer.setting("local_port", .int(54321)),
    peer.setting("expected_nonce", .string(UUID().uuidString)),
    peer.setting("connected", .bool(false)), peer.setting("greeting", .string("ssh succeeded")),
    .null,
  ] {
    #expect(!PeerEvidence.correlated(target: target, peer: invalid))
  }
  #expect(!PeerEvidence.correlated(target: target.setting("accepted", .array([])), peer: peer))
}

@MainActor private final class RestartFixture {
  let file: URL
  let token = UUID().uuidString
  var session: MeasurementSession
  var generation = 1
  var resumed = false
  var samples = 0
  init(file: URL) {
    self.file = file
    session = MeasurementSession(file: file, artifactID: "artifact")
  }
  var context: JSON {
    .obj([
      ("pid", .int(generation)), ("process_instance", .string("instance-\(generation)")),
      ("cdhash", .string("hash")), ("bundle_path", .string("/fixture.app")),
      ("build_receipt", .obj([("source", .string("commit"))])),
      ("launched_by", .string("launch_agent")),
    ])
  }
  func transport(_ words: [String], _ timeout: Int32, _ emit: @escaping @Sendable (String) -> Void)
    async -> String?
  {
    let id = words[1]
    let command = Array(words.dropFirst(2))
    let result: JSON
    if command == ["ping"] {
      result = .obj([("pong", .bool(true)), ("context", context)])
    } else if command == ["session", "resume", token] {
      resumed = session.resume(token)
      result =
        resumed ? .obj([("session", .bool(true))]) : .obj([("error", .string("resume refused"))])
    } else if command == ["session", token, "sample"], session.enter(token) {
      samples += 1
      session.leave()
      result = .obj([("sample", .bool(true))])
    } else {
      result = .obj([("error", .string("unowned effect"))])
    }
    emit(CommandProtocol.result(result, id: id).compact())
    emit(CommandProtocol.completion(id: id, count: 1, success: result["error"] == nil).compact())
    return nil
  }
}

@Test @MainActor func restartActuallyRestoresOwnerBeforeNextMeasurementAndFailsClosed() async throws
{
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let fixture = RestartFixture(file: root.appendingPathComponent("claim.json"))
  #expect(fixture.session.begin(fixture.token))
  let before = fixture.context
  let executor = AgentExecutor(
    sessionToken: fixture.token, expectedProbes: { _ in nil }, transport: fixture.transport,
    restartAgent: {
      fixture.generation += 1
      fixture.session = MeasurementSession(file: fixture.file, artifactID: "artifact")
      #expect(!fixture.session.isIdle)
      #expect(!fixture.session.enter(fixture.token))
    })
  let context = try await executor.restart(previousContext: before)
  #expect(context["pid"]?.intValue == 2)
  #expect(fixture.resumed)
  _ = try await executor.call(["sample"])
  #expect(fixture.samples == 1)
  let failing = AgentExecutor(
    sessionToken: fixture.token, expectedProbes: { _ in nil }, transport: fixture.transport,
    restartAgent: { throw TrialAbort.failed("injected launchctl failure") })
  do {
    _ = try await failing.restart(previousContext: context)
    Issue.record("restart failure accepted")
  } catch {}
  #expect(fixture.samples == 1)
  #expect(!fixture.session.isIdle)
  #expect(fixture.session.end(fixture.token))
}

@Test @MainActor func refusedRestartResumeKeepsBackgroundExcluded() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let fixture = RestartFixture(file: root.appendingPathComponent("claim.json"))
  #expect(fixture.session.begin(fixture.token))
  let before = fixture.context
  let executor = AgentExecutor(
    sessionToken: fixture.token, expectedProbes: { _ in nil }, transport: fixture.transport,
    restartAgent: {
      fixture.generation += 1
      fixture.session = MeasurementSession(file: fixture.file, artifactID: "different-artifact")
    })
  do {
    _ = try await executor.restart(previousContext: before)
    Issue.record("resume refusal accepted")
  } catch {}
  #expect(!fixture.resumed)
  #expect(!fixture.session.isIdle)
  #expect(!fixture.session.enter(nil))
  #expect(!fixture.session.enter(fixture.token))
  #expect(!fixture.session.end(fixture.token))
  #expect(fixture.samples == 0)
}

@Test @MainActor func persistenceFailureStopsLaterDirectEffects() async throws {
  let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try "blocker".write(to: blocker, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: blocker) }
  var effects = 0
  let spec = TrialSpec(
    name: "persist", items: [], effort: 0, summary: "", humanActions: "",
    run: { env in
      try env.record(.obj([("attempt", .int(1))]))
      effects += 1
    })
  let env = TrialEnv(
    spec: spec, executor: InProcessExecutor { _, _ in }, outDirectory: blocker, count: 1,
    options: [:])
  do {
    try await spec.run(env)
    Issue.record("persistence failure did not unwind")
  } catch {}
  #expect(effects == 0)
  #expect(env.report.status == .error)
  #expect(env.report.json(context: .null)["evidence"]?["complete"] == .bool(false))
}
