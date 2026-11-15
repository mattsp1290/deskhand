import AppKit
import CoreGraphics
import Foundation

/// One `CGWindowListCopyWindowInfo` entry. Window titles are never recorded (they can carry
/// private text); only whether one was readable, which needs Screen Recording.
public struct WindowEntry {
  public let number: Int
  public let ownerPID: pid_t?
  public let ownerName: String?
  public let layer: Int?
  public let bounds: CGRect?
  public let alpha: Double?
  public let titleReadable: Bool
  public let sharingState: Int?

  public init(_ info: [String: Any]) {
    number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
    ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    ownerName = info[kCGWindowOwnerName as String] as? String
    layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
    bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap {
      CGRect(dictionaryRepresentation: $0 as CFDictionary)
    }
    alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
    titleReadable = info[kCGWindowName as String] != nil
    sharingState = (info[kCGWindowSharingState as String] as? NSNumber)?.intValue
  }

  public var json: JSON {
    .obj([
      ("number", .int(number)), ("owner_pid", .int(ownerPID.map(Int.init))),
      ("owner_name", .str(ownerName)), ("layer", .int(layer)),
      ("bounds", bounds.map(Geometry.json).orNull), ("alpha", .num(alpha)),
      ("title_readable", .bool(titleReadable)), ("sharing_state", .int(sharingState)),
    ])
  }
}

public enum WindowList {
  /// On-screen windows, front to back.
  public static func onScreen(includeDesktop: Bool = true) -> [WindowEntry] {
    var options: CGWindowListOption = [.optionOnScreenOnly]
    if !includeDesktop { options.insert(.excludeDesktopElements) }
    let list = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.map(WindowEntry.init)
  }

  /// Front-to-back windows containing `point` (global display coordinates, top-left origin).
  public static func stack(at point: CGPoint, in windows: [WindowEntry]? = nil) -> [WindowEntry] {
    (windows ?? onScreen()).filter { $0.bounds?.contains(point) == true }
  }

  /// The window AppKit says a mouse-down at `point` would hit (`NSWindow.windowNumber(at:)`).
  public static func eventTargetWindowNumber(at point: CGPoint) -> Int {
    NSWindow.windowNumber(
      at: Geometry.cocoaPoint(fromGlobal: point), belowWindowWithWindowNumber: 0)
  }
}

/// Conversions between global display coordinates (top-left origin of the main display, y down;
/// CoreGraphics and ScreenCaptureKit) and Cocoa screen coordinates (bottom-left, y up).
public enum Geometry {
  public static var primaryHeight: CGFloat {
    NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
  }

  public static func cocoaRect(fromGlobal rect: CGRect) -> NSRect {
    NSRect(
      x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height, width: rect.width,
      height: rect.height)
  }

  public static func cocoaPoint(fromGlobal point: CGPoint) -> NSPoint {
    NSPoint(x: point.x, y: primaryHeight - point.y)
  }

  public static func globalPoint(fromCocoa point: NSPoint) -> CGPoint {
    CGPoint(x: point.x, y: primaryHeight - point.y)
  }

  public nonisolated static func json(_ rect: CGRect) -> JSON {
    .obj([
      ("x", .double(rect.origin.x)), ("y", .double(rect.origin.y)),
      ("width", .double(rect.width)), ("height", .double(rect.height)),
    ])
  }

  public nonisolated static func json(_ point: CGPoint) -> JSON {
    .obj([("x", .double(point.x)), ("y", .double(point.y))])
  }
}

/// A recorded event delivered to a harness window.
public nonisolated struct ReceivedEvent: Sendable {
  public let identity: EventIdentity?
  public let eventType: CGEventType?
  public let kind: String
  public let window: Int
  public let globalLocation: CGPoint
  public let keyCode: UInt16?
  public let characters: String?
  public let modifiers: UInt
  /// `NSEvent.timestamp`: seconds of system uptime, the same clock as
  /// `ProcessInfo.systemUptime`.
  public let timestamp: TimeInterval
  public let receivedUptime: TimeInterval
  public let receivedMonotonicMs: Double

  public var json: JSON {
    .obj([
      ("identity", .str(identity.map { String($0.rawValue) })),
      ("event_type", .int(eventType.map { Int($0.rawValue) })),
      ("kind", .string(kind)), ("window", .int(window)),
      ("global", Geometry.json(globalLocation)), ("key_code", .int(keyCode.map(Int.init))),
      ("characters_length", .int(characters?.count)), ("modifiers", .int(Int(modifiers))),
      ("event_uptime", .double(timestamp)), ("received_uptime", .double(receivedUptime)),
      ("received_monotonic_ms", .double(receivedMonotonicMs)),
    ])
  }
}

/// A view that records every mouse and key event it receives.
public final class RecordingView: NSView {
  public var color: NSColor = .magenta { didSet { needsDisplay = true } }
  public var onEvent: ((ReceivedEvent) -> Void)?

  public override var acceptsFirstResponder: Bool { true }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  public override var isFlipped: Bool { true }

  public override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    dirtyRect.fill()
  }

  private func record(_ kind: String, _ event: NSEvent) {
    let isKey = event.type == .keyDown || event.type == .keyUp
    let screenPoint = window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? .zero
    onEvent?(
      ReceivedEvent(
        identity: event.cgEvent.flatMap {
          EventIdentity($0.getIntegerValueField(.eventSourceUserData))
        },
        eventType: event.cgEvent?.type,
        kind: kind, window: window?.windowNumber ?? 0,
        globalLocation: Geometry.globalPoint(fromCocoa: screenPoint),
        keyCode: isKey ? event.keyCode : nil,
        characters: isKey ? event.characters : nil, modifiers: event.modifierFlags.rawValue,
        timestamp: event.timestamp, receivedUptime: ProcessInfo.processInfo.systemUptime,
        receivedMonotonicMs: Clock.monoMs()))
  }

  public override func mouseDown(with event: NSEvent) { record("left_down", event) }
  public override func mouseUp(with event: NSEvent) { record("left_up", event) }
  public override func mouseDragged(with event: NSEvent) { record("left_dragged", event) }
  public override func mouseMoved(with event: NSEvent) { record("mouse_moved", event) }
  public override func rightMouseDown(with event: NSEvent) { record("right_down", event) }
  public override func rightMouseUp(with event: NSEvent) { record("right_up", event) }
  public override func otherMouseDown(with event: NSEvent) { record("other_down", event) }
  public override func otherMouseUp(with event: NSEvent) { record("other_up", event) }
  public override func scrollWheel(with event: NSEvent) { record("scroll", event) }
  public override func keyDown(with event: NSEvent) { record("key_down", event) }
  public override func keyUp(with event: NSEvent) { record("key_up", event) }
  public override func flagsChanged(with event: NSEvent) { record("flags_changed", event) }
}

/// A borderless harness window placed in global coordinates. It can become key, so it can take
/// keystrokes once a posted click activates the harness.
public final class HarnessWindow: NSWindow {
  public let view = RecordingView()
  public private(set) var received: [ReceivedEvent] = []

  public override var canBecomeKey: Bool { true }
  public override var canBecomeMain: Bool { true }

  public init(global rect: CGRect, color: NSColor, level: NSWindow.Level = .floating) {
    super.init(
      contentRect: Geometry.cocoaRect(fromGlobal: rect), styleMask: [.borderless],
      backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    self.level = level
    backgroundColor = color
    isOpaque = true
    hasShadow = false
    acceptsMouseMovedEvents = true
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    view.color = color
    view.frame = NSRect(origin: .zero, size: Geometry.cocoaRect(fromGlobal: rect).size)
    contentView = view
    view.onEvent = { [weak self] event in self?.received.append(event) }
  }

  /// The window's frame in global coordinates.
  public var globalFrame: CGRect {
    let cocoa = frame
    return CGRect(
      x: cocoa.origin.x, y: Geometry.primaryHeight - cocoa.origin.y - cocoa.height,
      width: cocoa.width, height: cocoa.height)
  }

  public var globalCenter: CGPoint { CGPoint(x: globalFrame.midX, y: globalFrame.midY) }

  public func show() {
    orderFrontRegardless()
    display()
  }

  public func clearReceived() { received.removeAll() }

  public func received(_ kind: String) -> [ReceivedEvent] { received.filter { $0.kind == kind } }
}

/// Brings the harness to the front; returns whether it is frontmost afterwards.
public func activateHarness() async -> Bool {
  NSApplication.shared.activate(ignoringOtherApps: true)
  for _ in 0..<20 {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { return true }
    await Clock.sleep(ms: 50)
  }
  return NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
}

/// Lets the run loop draw and deliver events.
public func settle(ms: Int = 250) async {
  await Clock.sleep(ms: ms)
}
