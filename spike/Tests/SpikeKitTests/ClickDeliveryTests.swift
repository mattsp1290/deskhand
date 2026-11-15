import AppKit
import CoreGraphics
import Testing

@testable import SpikeKit

private func observation(
  _ kind: String, _ identity: Int64?, _ type: CGEventType?, _ time: Double
) -> ReceivedEvent {
  ReceivedEvent(
    identity: identity.flatMap(EventIdentity.init), eventType: type, kind: kind, window: 1,
    globalLocation: .zero, keyCode: nil, characters: nil, modifiers: 0,
    timestamp: (time - 500) / 1000, receivedUptime: (time - 500) / 1000,
    receivedMonotonicMs: time)
}

@Test func clickDeliveryRequiresExactlyTheCurrentPair() {
  let down = EventPost(identity: EventIdentity(1)!, eventType: .leftMouseDown, monotonicMs: 1000)
  let up = EventPost(identity: EventIdentity(2)!, eventType: .leftMouseUp, monotonicMs: 1040)
  let click = ClickReceipt(down: down, up: up)
  let d = observation("left_down", 1, .leftMouseDown, 1001)
  let u = observation("left_up", 2, .leftMouseUp, 1041)
  let movement = observation("mouse_moved", 3, .mouseMoved, 1050)
  #expect(click.delivery(in: [d, u], startedMs: 999, endedMs: 1100).qualified)
  #expect(click.delivery(in: [d, movement, u], startedMs: 999, endedMs: 1100).qualified)
  for events in [
    [], [d], [u], [u, d], [d, d, u], [d, u, u],
    [d, observation("left_up", 99, .leftMouseUp, 1041)],
    [d, observation("left_up", nil, .leftMouseUp, 1041)],
    [d, observation("left_up", 2, nil, 1041)],
    [d, observation("left_up", 2, .rightMouseUp, 1041)],
    [d, observation("left_up", 2, .leftMouseUp, 900)],
    [d, observation("left_up", 2, .leftMouseUp, 1030)],
    [d, observation("left_up", 2, .leftMouseUp, 1101)],
    [d, u, observation("right_down", 90, .rightMouseDown, 1050)],
  ] {
    #expect(!click.delivery(in: events, startedMs: 999, endedMs: 1100).qualified)
  }
  for invalid in [
    ClickReceipt(down: nil, up: up), ClickReceipt(down: down, up: nil),
    ClickReceipt(down: up, up: down),
    ClickReceipt(
      down: down, up: EventPost(identity: down.identity, eventType: .leftMouseUp, monotonicMs: 1040)
    ),
  ] { #expect(!invalid.delivery(in: [d, u], startedMs: 999, endedMs: 1100).qualified) }
  #expect(!click.delivery(in: [d, u], startedMs: 1001, endedMs: 1100).qualified)
  #expect(!click.delivery(in: [d, u], startedMs: 999, endedMs: 1039).qualified)
  #expect(!click.delivery(in: [d, u], startedMs: .nan, endedMs: 1100).qualified)
  #expect(click.json["up"]?["identity"]?.stringValue == "2")
  #expect(u.json["identity"]?.stringValue == "2")
}

@Test func identityAllocationNeverReusesAndStopsAtExhaustion() async {
  #expect(EventIdentity(0) == nil)
  var sequence = EventIdentitySequence(start: Int64.max - 1)
  #expect(sequence.next()?.rawValue == Int64.max - 1)
  #expect(sequence.next()?.rawValue == Int64.max)
  #expect(sequence.next() == nil)
  #expect(sequence.next() == nil)
  let values = await withTaskGroup(of: Int64?.self) { group in
    for _ in 0..<1000 { group.addTask { EventIdentity.next()?.rawValue } }
    var values: [Int64] = []
    for await value in group { if let value { values.append(value) } }
    return values
  }
  #expect(values.count == 1000)
  #expect(Set(values).count == 1000)
}

@Test func inertCocoaBridgeRetainsTagAndEventType() throws {
  for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    let event = try #require(
      CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left))
    let identity = try #require(EventIdentity.next())
    event.setIntegerValueField(.eventSourceUserData, value: identity.rawValue)
    let cocoa = try #require(NSEvent(cgEvent: event))
    let bridged = try #require(cocoa.cgEvent)
    #expect(bridged.type == type)
    #expect(bridged.getIntegerValueField(.eventSourceUserData) == identity.rawValue)
  }
}
