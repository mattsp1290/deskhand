import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SpikeKit

enum InputGuard {
  static func begin(_ report: inout ProbeReport) -> Bool {
    let (safe, why) = Signals.safeToPost()
    report.set("preflights", Signals.preflights())
    guard safe else {
      report.skip(why)
      return false
    }
    if !CGPreflightPostEventAccess() {
      report.block(on: .postEvent, "CGPreflightPostEventAccess is false")
    }
    return true
  }

  static func ownsTopmost(at point: CGPoint) -> Bool {
    WindowList.stack(at: point).first?.ownerPID == getpid()
  }

  static func ownsKeyboard() -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
      && NSApplication.shared.keyWindow != nil
  }
}

final class InputRig {
  let window: HarnessWindow
  let previousFrontmost = NSWorkspace.shared.frontmostApplication
  let startPointer = Post.location()

  init(width: CGFloat = 360, height: CGFloat = 240, color: NSColor = .systemTeal) {
    let main = CGDisplayBounds(CGMainDisplayID())
    window = HarnessWindow(
      global: CGRect(
        x: main.midX - width / 2, y: main.midY - height / 2, width: width, height: height),
      color: color, level: .popUpMenu)
  }

  func show() async {
    window.show()
    await settle(ms: 400)
  }

  func focus() async -> Bool {
    let point = window.globalCenter
    if InputGuard.ownsTopmost(at: point) {
      await Post.click(at: point)
      await settle(ms: 300)
    }
    if !InputGuard.ownsKeyboard() {
      _ = await activateHarness()
      window.makeKeyAndOrderFront(nil)
      await settle(ms: 200)
    }
    window.makeFirstResponder(window.view)
    return InputGuard.ownsKeyboard()
  }

  func tearDown() async {
    window.close()
    Post.move(to: startPointer)
    if let previous = previousFrontmost, previous.processIdentifier != getpid() {
      previous.activate()
    }
    await settle(ms: 200)
  }
}

enum Focus {
  static func focusedApplicationPID() -> (pid: pid_t?, error: String?) {
    guard AXIsProcessTrusted() else { return (nil, "accessibility_untrusted") }
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value)
    guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return (nil, "AXError \(error.rawValue)")
    }
    var pid: pid_t = 0
    let element = unsafeDowncast(value, to: AXUIElement.self)
    guard AXUIElementGetPid(element, &pid) == .success else { return (nil, "no pid") }
    return (pid, nil)
  }

  static func focusedElement() -> JSON {
    guard AXIsProcessTrusted() else { return .obj([("error", .string("accessibility_untrusted"))]) }
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value)
    guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return .obj([("error", .string("AXError \(error.rawValue)"))])
    }
    let element = unsafeDowncast(value, to: AXUIElement.self)
    var pid: pid_t = 0
    _ = AXUIElementGetPid(element, &pid)
    var role: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    return .obj([
      ("pid", .int(Int(pid))), ("role", .str(role as? String)),
      ("owner", .str(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)),
    ])
  }

  static func json() -> JSON {
    let focused = focusedApplicationPID()
    let front = NSWorkspace.shared.frontmostApplication
    return .obj([
      ("ax_focused_pid", .int(focused.pid.map(Int.init))), ("ax_error", .str(focused.error)),
      (
        "ax_focused_bundle_id",
        .str(focused.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier })
      ),
      ("frontmost_pid", .int(front.map { Int($0.processIdentifier) })),
      ("frontmost_bundle_id", .str(front?.bundleIdentifier)),
      ("harness_pid", .int(Int(getpid()))),
    ])
  }
}

func percentiles(_ values: [Double]) -> JSON {
  guard !values.isEmpty else { return .null }
  let sorted = values.sorted()
  func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
  return .obj([
    ("count", .int(sorted.count)), ("min", .double(sorted[0])), ("p50", .double(at(0.5))),
    ("p95", .double(at(0.95))), ("max", .double(sorted[sorted.count - 1])),
  ])
}
