import Foundation
import SpikeKit

enum SelfCheck {
  enum Failure: Error { case invalidJSON, duplicateCatalog, writeDidNotFail }

  static func run() throws -> JSON {
    let absent: JSON? = nil
    let present: JSON? = .string("value")
    guard absent.orNull.compact() == "null", present.orNull == .string("value") else {
      throw Failure.invalidJSON
    }
    let names = Catalog.probes.map(\.name)
    let trials = Catalog.trials.map(\.name)
    guard Set(names).count == names.count, Set(trials).count == trials.count else {
      throw Failure.duplicateCatalog
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("report.json")
    try EvidenceWriter.write(JSON.obj([("optional", absent.orNull)]).pretty(), to: file)
    guard JSON.parse(try String(contentsOf: file, encoding: .utf8))?["optional"] == .null else {
      throw Failure.invalidJSON
    }
    do {
      try EvidenceWriter.write("must fail", to: file.appendingPathComponent("child.json"))
    } catch {
      return .obj([
        ("selfcheck", .bool(true)), ("probes", .int(names.count)), ("trials", .int(trials.count)),
      ])
    }
    throw Failure.writeDidNotFail
  }
}
