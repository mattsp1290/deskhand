import CoreGraphics
import Synchronization

public nonisolated struct EventIdentity: Sendable, Equatable {
  public let rawValue: Int64

  public init?(_ rawValue: Int64) {
    guard rawValue != 0 else { return nil }
    self.rawValue = rawValue
  }

  private static let sequence = Mutex(EventIdentitySequence())

  static func next() -> EventIdentity? {
    sequence.withLock { $0.next() }
  }
}

nonisolated struct EventIdentitySequence {
  private var value: Int64?

  init(start: Int64 = Int64.random(in: 1...(Int64.max / 2))) {
    value = start > 0 ? start : nil
  }

  mutating func next() -> EventIdentity? {
    guard let current = value else { return nil }
    value = current == Int64.max ? nil : current + 1
    return EventIdentity(current)
  }
}

public nonisolated enum ClickDelivery: Sendable, Equatable {
  case delivered
  case inconclusive(String)

  public var qualified: Bool { self == .delivered }

  public var json: JSON {
    switch self {
    case .delivered: .string("delivered")
    case .inconclusive(let reason): .obj([("inconclusive", .string(reason))])
    }
  }
}

extension ClickReceipt {
  public func delivery(in events: [ReceivedEvent], startedMs: Double, endedMs: Double)
    -> ClickDelivery
  {
    guard let down, let up,
      down.eventType == .leftMouseDown, up.eventType == .leftMouseUp,
      down.identity != up.identity,
      startedMs.isFinite, endedMs.isFinite,
      down.monotonicMs.isFinite, up.monotonicMs.isFinite,
      startedMs <= down.monotonicMs, down.monotonicMs <= up.monotonicMs,
      up.monotonicMs <= endedMs
    else { return .inconclusive("missing or invalid current click receipts") }
    let clicks = events.filter {
      ["left_down", "left_up", "right_down", "right_up", "other_down", "other_up"].contains($0.kind)
        || [
          .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
          .otherMouseUp,
        ].contains($0.eventType)
    }
    guard clicks.count == 2 else {
      return .inconclusive("missing, duplicate, or unrelated click delivery")
    }
    for (event, post, kind) in [(clicks[0], down, "left_down"), (clicks[1], up, "left_up")] {
      let receivedMs = event.receivedMonotonicMs
      guard event.identity == post.identity, event.eventType == post.eventType, event.kind == kind,
        receivedMs.isFinite,
        post.monotonicMs <= receivedMs, receivedMs <= endedMs
      else { return .inconclusive("click identity, type, or observation interval does not match") }
    }
    guard clicks[0].receivedMonotonicMs <= clicks[1].receivedMonotonicMs
    else { return .inconclusive("click delivery is out of order") }
    return .delivered
  }

  public var json: JSON {
    .obj([
      ("down", down.map(\.json).orNull), ("up", up.map(\.json).orNull),
      ("all_posted", .bool(allPosted)),
    ])
  }
}
