import Foundation

public nonisolated enum IdleAssessment: Equatable {
  case reset
  case unchanged
  case inconclusive(String)

  public var json: JSON {
    switch self {
    case .reset: .string("reset")
    case .unchanged: .string("unchanged")
    case .inconclusive(let reason): .obj([("inconclusive", .string(reason))])
    }
  }
}

public nonisolated struct LockReference {
  public enum Provenance { case independent, candidateAgreement, unknown }
  public let provenance: Provenance
  public let lockedIndices: Set<Int>
  public init(provenance: Provenance, lockedIndices: Set<Int>) {
    self.provenance = provenance
    self.lockedIndices = lockedIndices
  }
}

public nonisolated enum MeasurementAnalysis {
  public static func idle(delivered: Bool, before: Double?, after: Double?, elapsed: Double)
    -> IdleAssessment
  {
    guard delivered else { return .inconclusive("input was not delivered") }
    guard let before, let after, before.isFinite, after.isFinite, before >= 1, after >= 0 else {
      return .inconclusive("unreadable counter or insufficient idle baseline")
    }
    guard elapsed.isFinite, elapsed > 0, elapsed <= 0.5 else {
      return .inconclusive("observation was too late")
    }
    if after <= elapsed + 0.1 { return .reset }
    if after >= before + elapsed - 0.1 { return .unchanged }
    return .inconclusive("counter change does not establish reset or continued idle")
  }

  public static func mainDisplayAsleep(_ sample: JSON) -> Bool {
    sample["displays"]?.arrayValue?.contains {
      $0["main"]?.boolValue == true && $0["asleep"]?.boolValue == true
    } == true
  }

  public static func wake(
    sleepSucceeded: Bool, finalPoll: JSON, beforeAssertion: JSON, awakeAfter: Bool
  ) -> JSON {
    let valid = sleepSucceeded && mainDisplayAsleep(finalPoll) && mainDisplayAsleep(beforeAssertion)
    return .obj([
      ("valid", .bool(valid)), ("woke", .bool(valid && awakeAfter)),
      (
        "reason",
        valid
          ? .null : .string("sleep request and immediate asleep prerequisite were not established")
      ),
    ])
  }

  public static func lock(_ samples: [JSON], t0: Double, reference: LockReference) -> JSON {
    let keys = Set(samples.flatMap { $0["lock"]?.members?.map(\.key) ?? [] }).sorted()
    return .obj(
      keys.map { key in
        var firstLocked: Double?
        var falseCount = 0
        var unknownCount = 0
        for (index, sample) in samples.enumerated() {
          let raw = sample["lock"]?[key]?.boolValue
          let locked = raw.map { key == "on_console" ? !$0 : $0 }
          if locked == true, firstLocked == nil {
            firstLocked = (sample["t"]?["mono_ms"]?.doubleValue ?? t0) - t0
          }
          if reference.lockedIndices.contains(index) {
            if locked == false { falseCount += 1 }
            if locked == nil { unknownCount += 1 }
          }
        }
        let independent = reference.provenance == .independent && !reference.lockedIndices.isEmpty
        return (
          key,
          .obj([
            ("first_locked_ms", .num(firstLocked)), ("false_unlocked_samples", .int(falseCount)),
            ("unknown_samples", .int(unknownCount)),
            ("unlocked_while_locked", independent ? .bool(falseCount > 0) : .null),
            (
              "safety_conclusion",
              .string(
                independent && unknownCount == 0
                  ? (falseCount == 0 ? "no_false_unlock_observed" : "false_unlock_observed")
                  : "inconclusive")
            ),
            (
              "reference",
              .string(
                reference.provenance == .independent
                  ? "independent"
                  : reference.provenance == .candidateAgreement ? "candidate_agreement" : "unknown")
            ),
          ])
        )
      })
  }
}

public nonisolated enum NumericArguments {
  public static func validate(_ words: [String]) throws {
    for (index, word) in words.enumerated() {
      let range: ClosedRange<Int>
      switch word {
      case "--count": range = 1...Int.max
      case "--port", "--listener-port": range = 1...65534
      case "--interval", "--capture-interval": range = 1...(Int.max / 1_000_000_000)
      default: continue
      }
      guard index + 1 < words.count, let value = Int(words[index + 1]), range.contains(value) else {
        throw TrialAbort.failed("invalid numeric value for \(word)")
      }
    }
  }
}
