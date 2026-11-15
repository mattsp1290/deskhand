import Foundation
import Testing

@testable import SpikeKit

@Test func optionalJSONEncoding() {
  let absent: JSON? = nil
  let present: JSON? = .string("value")
  #expect(absent.orNull.compact() == "null")
  #expect(present.orNull.compact() == "\"value\"")
  #expect(JSON.str(nil) == .null)
  #expect(JSON.num(1.5) == .double(1.5))
}

@Test func evidenceWriteFailurePropagates() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let blocker = directory.appendingPathComponent("file")
  try "existing".write(to: blocker, atomically: true, encoding: .utf8)
  #expect(throws: (any Error).self) {
    try EvidenceWriter.write("evidence", to: blocker.appendingPathComponent("report.json"))
  }
  #expect(try String(contentsOf: blocker, encoding: .utf8) == "existing")
}

@Test @MainActor func failedTrialCannotComplete() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try "block".write(to: directory, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: directory) }
  let spec = TrialSpec(
    name: "test", items: [], effort: 0, summary: "test", humanActions: "none", run: { _ in })
  let env = TrialEnv(
    spec: spec, executor: InProcessExecutor { _, _ in }, outDirectory: directory, count: 1,
    options: [:])
  try? env.finish()
  #expect(env.persistenceError != nil)
  #expect(env.report.status == .error)
  #expect(env.report.json(context: .null)["evidence"]?["complete"] == .bool(false))
}

@Test @MainActor func measurementSessionOwnsWholeTrial() {
  let session = MeasurementSession()
  let owner = UUID().uuidString
  let other = UUID().uuidString
  #expect(session.begin(owner))
  #expect(!session.begin(other))
  #expect(!session.enter(nil))
  #expect(!session.enter(other))
  #expect(session.enter(owner))
  #expect(!session.enter(owner))
  #expect(!session.end(owner))
  session.leave()
  #expect(!session.isIdle)
  #expect(!session.end(other))
  #expect(session.enter(owner))
  session.leave()
  #expect(session.end(owner))
  #expect(session.isIdle)
}

@Test @MainActor func executorFailureCannotCompleteTrial() async {
  let spec = TrialSpec(
    name: "test", items: [], effort: 0, summary: "test", humanActions: "none", run: { _ in })
  let executor = InProcessExecutor { _, emit in
    emit(.obj([("error", .string("unreachable"))]))
    emit(.obj([("status", .string("blocked_on_permission"))]))
  }
  let env = TrialEnv(spec: spec, executor: executor, outDirectory: nil, count: 1, options: [:])
  _ = try? await env.call(["sample"])
  try? env.finish()
  #expect(env.report.status == .error)
  #expect(env.report.json(context: .null)["evidence"]?["complete"] == .bool(false))
}
