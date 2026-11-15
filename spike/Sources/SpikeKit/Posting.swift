import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// CGEvent posting. `CGEvent.post` never reports failure: without the grant macOS drops the
/// event silently, so every probe checks delivery separately.
public enum Post {
  /// The source deskhand v0 would use by default. Probes also try the other states.
  public static func source(_ state: CGEventSourceStateID = .hidSystemState) -> CGEventSource? {
    CGEventSource(stateID: state)
  }

  @discardableResult
  public static func key(
    _ code: Int, down: Bool, flags: CGEventFlags = [], tap: CGEventTapLocation = .cghidEventTap,
    state: CGEventSourceStateID = .hidSystemState
  ) -> Bool {
    guard
      let event = CGEvent(
        keyboardEventSource: source(state), virtualKey: CGKeyCode(code), keyDown: down)
    else { return false }
    event.flags = flags
    event.post(tap: tap)
    return true
  }

  /// Presses `code` with `modifiers` held: modifier downs, key down/up, modifier ups.
  @discardableResult
  public static func chord(
    _ code: Int, modifiers: [Int] = [], tap: CGEventTapLocation = .cghidEventTap,
    state: CGEventSourceStateID = .hidSystemState, holdMs: Int = 30
  ) async -> Bool {
    var flags: CGEventFlags = []
    var ok = true
    for modifier in modifiers {
      flags.insert(flag(for: modifier))
      ok = key(modifier, down: true, flags: flags, tap: tap, state: state) && ok
    }
    ok = key(code, down: true, flags: flags, tap: tap, state: state) && ok
    await Clock.sleep(ms: holdMs)
    ok = key(code, down: false, flags: flags, tap: tap, state: state) && ok
    for modifier in modifiers.reversed() {
      flags.remove(flag(for: modifier))
      ok = key(modifier, down: false, flags: flags, tap: tap, state: state) && ok
    }
    return ok
  }

  public static func flag(for modifier: Int) -> CGEventFlags {
    switch modifier {
    case kVK_Command, kVK_RightCommand: .maskCommand
    case kVK_Shift, kVK_RightShift: .maskShift
    case kVK_Option, kVK_RightOption: .maskAlternate
    case kVK_Control, kVK_RightControl: .maskControl
    case kVK_Function: .maskSecondaryFn
    default: []
    }
  }

  /// Types lowercase ASCII letters (used only for harmless markers such as "xyz").
  @discardableResult
  public static func type(
    _ text: String, tap: CGEventTapLocation = .cghidEventTap,
    state: CGEventSourceStateID = .hidSystemState
  ) async -> Bool {
    var ok = true
    for character in text {
      guard let code = letterCodes[character] else { continue }
      ok = key(code, down: true, tap: tap, state: state) && ok
      await Clock.sleep(ms: 15)
      ok = key(code, down: false, tap: tap, state: state) && ok
      await Clock.sleep(ms: 15)
    }
    return ok
  }

  public static let letterCodes: [Character: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
    "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
    "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
    "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
    "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
    "z": kVK_ANSI_Z,
  ]

  @discardableResult
  public static func mouse(
    _ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left,
    tap: CGEventTapLocation = .cghidEventTap, state: CGEventSourceStateID = .hidSystemState,
    clickState: Int64 = 1
  ) -> Bool {
    guard
      let event = CGEvent(
        mouseEventSource: source(state), mouseType: type, mouseCursorPosition: point,
        mouseButton: button)
    else { return false }
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    event.post(tap: tap)
    return true
  }

  @discardableResult
  public static func move(
    to point: CGPoint, tap: CGEventTapLocation = .cghidEventTap,
    state: CGEventSourceStateID = .hidSystemState
  ) -> Bool {
    mouse(.mouseMoved, at: point, tap: tap, state: state)
  }

  @discardableResult
  public static func click(
    at point: CGPoint, tap: CGEventTapLocation = .cghidEventTap,
    state: CGEventSourceStateID = .hidSystemState
  ) async -> Bool {
    let down = mouse(.leftMouseDown, at: point, tap: tap, state: state)
    await Clock.sleep(ms: 40)
    let up = mouse(.leftMouseUp, at: point, tap: tap, state: state)
    return down && up
  }

  /// Moves in small steps so the path is a real pointer movement (hot corners need one).
  public static func glide(
    to point: CGPoint, steps: Int = 20, tap: CGEventTapLocation = .cghidEventTap
  ) async {
    let start = location()
    for step in 1...steps {
      let t = CGFloat(step) / CGFloat(steps)
      move(
        to: CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t),
        tap: tap)
      await Clock.sleep(ms: 10)
    }
  }

  public static func location() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
  }
}
