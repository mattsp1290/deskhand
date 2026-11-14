/// One synthetic input event: exactly what `events_posted` counts as one (contract 12.2). Positions
/// are global points. The platform sets on every event the flags of the modifiers it has posted down
/// and not yet up.
public enum InputEvent: Hashable, Sendable {
    /// `text` is what a `type` event inserts through its carrier key, so the layout does not matter
    /// and no shortcut fires (contract 6.5). `nil` for a `press`.
    case keyDown(PostedKeyCode, text: String?)
    case keyUp(PostedKeyCode, text: String?)
    /// On macOS a flags-changed event.
    case modifierDown(PostedKeyCode)
    case modifierUp(PostedKeyCode)
    /// `dragging` names the button held while the pointer moves, so the platform posts a drag event.
    case pointerMove(to: GlobalPoint, dragging: MouseButton?)
    /// `clickCount` is this press's place in a multi-click: 1, 2 or 3.
    case buttonDown(MouseButton, at: GlobalPoint, clickCount: Int)
    case buttonUp(MouseButton, at: GlobalPoint, clickCount: Int)
    /// A delta in global points. Positive `dy` reveals content further down and positive `dx`
    /// further right, whatever the Mac's natural-scrolling setting (contract 6.4).
    case scroll(dx: Double, dy: Double, at: GlobalPoint)

    /// What this event puts down, which the held-input ledger records before it is posted.
    public var press: HeldInput? {
        switch self {
        case .keyDown(let code, _): .key(code)
        case .modifierDown(let code): .modifier(code)
        case .buttonDown(let button, _, _): .button(button)
        default: nil
        }
    }

    /// What this event lets up.
    public var release: HeldInput? {
        switch self {
        case .keyUp(let code, _): .key(code)
        case .modifierUp(let code): .modifier(code)
        case .buttonUp(let button, _, _): .button(button)
        default: nil
        }
    }
}

/// Posts input on the Mac. The executor calls it only after the held-input ledger and the checks of
/// contract 12.3 step 6, and the release handler only when cleanup is authorized (contract 12.8).
public protocol EventPoster: Sendable {
    /// Posts one event. A throw means it may or may not have reached the Mac.
    func post(_ event: InputEvent) throws

    /// Posts the up event that releases `input` where the pointer is now: a release never moves the
    /// pointer (contract 12.4) and nothing but a key-up or a button-up is posted (contract 12.8).
    func postRelease(_ input: HeldInput) throws
}

/// Turns key names into the codes the platform posts, under the layout active now (contract 6.5).
/// The code is what the ledger records, so a release needs nothing resolved again.
public protocol KeyCodeMapper: Sendable {
    /// The key that produces `key` unshifted, or `nil` when the layout has no such key; the call is
    /// then `invalid_argument`.
    func code(for key: Key) -> PostedKeyCode?

    func code(for modifier: Modifier) -> PostedKeyCode

    /// The key whose events carry the Unicode text of `type`.
    var textCarrier: PostedKeyCode { get }
}
