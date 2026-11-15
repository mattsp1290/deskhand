import Foundation
import Testing

@testable import SpikeKit

@Test func fractionalJSONIntegersAreRejected() {
  for value in [0.9, -0.9, 1.9] {
    #expect(JSON.double(value).intValue == nil)
  }
}

@Test func everyProtocolResultRequiresAnUnambiguousIdentity() throws {
  let id = "boundary"
  let a = CommandProtocol.result(.obj([("probe", .string("a"))]), id: id)
  let b = CommandProtocol.result(.obj([("probe", .string("b"))]), id: id)
  let unnamed = CommandProtocol.result(.obj([]), id: id)
  let done = CommandProtocol.completion(id: id, count: 2, success: true)
  let invalid: [[JSON]] = [
    [a, unnamed, done], [unnamed, a, done], [a, a, done], [b, a, done],
    [a, CommandProtocol.completion(id: id, count: 1, success: true)],
    [a, b, b, CommandProtocol.completion(id: id, count: 3, success: true)],
    [a, b, done.setting("result", .null)],
    [a.setting("complete", .null), b, done],
    [a.setting("count", .int(2)), b, done],
    [a.setting("success", .bool(true)), b, done],
  ]
  for frames in invalid {
    let lines = frames.map { $0.compact() }
    do {
      _ = try CommandProtocol.validate(lines, id: id, expectedProbes: ["a", "b"])
      Issue.record("invalid frames accepted: \(lines)")
    } catch let failure as CommandFailure {
      #expect(failure.rawLines == lines)
    }
  }
  let extra = [a, unnamed, done].map { $0.compact() }
  #expect(throws: CommandFailure.self) {
    try CommandProtocol.validate(extra, id: id, expectedProbes: ["a"])
  }
}

@Test func integerExtractionNeverTrapsOrNarrowsUnsignedValues() throws {
  for value in [
    Double.nan, .infinity, -.infinity, 1e30, -1e30, Double(Int.max), Double(Int.min).nextDown,
  ] {
    #expect(JSON.double(value).intValue == nil)
  }
  #expect(JSON.double(Double(Int.min)).intValue == Int.min)
  #expect(JSON.double(Double(Int.max).nextDown).intValue == Int(exactly: Double(Int.max).nextDown))
  #expect(JSON.int(Int.max).intValue == Int.max)
  #expect(JSON.int(Int.min).intValue == Int.min)
  #expect(JSON.double(0).intValue == 0)
  #expect(JSON.double(-12).intValue == -12)
  for value in [UInt64(Int.max) + 1, UInt64.max - 1, UInt64.max] {
    #expect(JSON.from(foundation: NSNumber(value: value)).intValue == nil)
    #expect(JSON.parse(String(value))?.intValue == nil)
  }
  #expect(JSON.from(foundation: NSNumber(value: UInt64(Int.max))).intValue == Int.max)
  #expect(JSON.parse(String(Int.max))?.intValue == Int.max)
  #expect(JSON.parse(String(Int.min))?.intValue == Int.min)
  #expect(JSON.from(foundation: NSNumber(value: true)) == .bool(true))
}

@Test func invalidProtocolCountsPreserveEveryEvidenceLine() {
  let report = CommandProtocol.result(.obj([("probe", .string("a"))]), id: "boundary").compact()
  for count in ["1.9", "1e30", "-1e30", "18446744073709551615", "NaN", "Infinity", "-1", "0", "2"] {
    let lines = [
      report, "{\"id\":\"boundary\",\"complete\":true,\"count\":\(count),\"success\":true}",
    ]
    do {
      _ = try CommandProtocol.validate(lines, id: "boundary", expectedProbes: ["a"])
      Issue.record("invalid count accepted: \(count)")
    } catch let failure as CommandFailure {
      #expect(failure.partialReports.count == 1)
      #expect(failure.rawLines == lines)
    } catch { Issue.record("unexpected error: \(error)") }
  }
}

@Test func clickCompletenessRequiresBothPostReceipts() {
  let down = EventPost(identity: EventIdentity(1)!, eventType: .leftMouseDown, monotonicMs: 1000)
  let up = EventPost(identity: EventIdentity(2)!, eventType: .leftMouseUp, monotonicMs: 1040)
  #expect(ClickReceipt(down: down, up: up).allPosted)
  #expect(!ClickReceipt(down: down, up: nil).allPosted)
  #expect(!ClickReceipt(down: nil, up: up).allPosted)
  #expect(!ClickReceipt(down: nil, up: nil).allPosted)
}

@Test func echoUsesActualMouseUpAndRetainsSignedOffsets() {
  for hold in [40.0, 75.0, 140.0] {
    for echo in [0.0, 20.0] {
      let up = 1000 + hold
      let read = up + 60
      #expect(
        MeasurementAnalysis.echoOffset(
          observedMs: read, idleSeconds: (read - up - echo) / 1000, postedMs: up) == echo)
    }
  }
  #expect(
    MeasurementAnalysis.echoOffset(observedMs: 1100, idleSeconds: 0.08, postedMs: 1040) == -20)
  #expect(MeasurementAnalysis.echoOffset(observedMs: 1100, idleSeconds: nil, postedMs: 1040) == nil)
  #expect(MeasurementAnalysis.echoOffset(observedMs: 1100, idleSeconds: 0.06, postedMs: nil) == nil)
  #expect(
    MeasurementAnalysis.echoOffset(observedMs: .infinity, idleSeconds: 0.06, postedMs: 1040) == nil)
  #expect(
    MeasurementAnalysis.echoOffset(observedMs: 1100, idleSeconds: -.infinity, postedMs: 1040) == nil
  )
  #expect(
    MeasurementAnalysis.echoOffset(observedMs: 1100, idleSeconds: -0.1, postedMs: 1040) == nil)
}
