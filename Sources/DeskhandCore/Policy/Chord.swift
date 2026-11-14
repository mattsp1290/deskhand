/// A key together with the exact set of modifiers held while it is pressed.
public struct Chord: Hashable, Sendable, CustomStringConvertible {
    public let modifiers: Set<Modifier>
    public let key: Key

    public init(_ modifiers: Set<Modifier>, _ key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    public init(_ press: KeyPress) {
        self.init(press.modifiers, press.key)
    }

    /// The chord as `details.shortcut` spells it (contract 9.2), the same spelling as ``KeyPress/shortcut``.
    public var shortcut: String {
        (modifiers.sorted().map(\.rawValue) + [key.rawValue]).joined(separator: "+")
    }

    public var description: String { shortcut }
}

/// One row of the default denied global shortcut list.
public struct DeniedChordEntry: Sendable {
    public let chord: Chord
    /// What macOS does with the chord by default.
    public let purpose: String
}

extension DeniedChordEntry {
    /// Global shortcuts that reach past the frontmost app: launchers, app and Space switchers, Force
    /// Quit, screenshots, log out and lock, input-source switching, and keyboard focus moves to the menu
    /// bar, Dock and status menus (where deskhand's own arming menu lives). A chord is matched exactly,
    /// so `command+space` does not deny `shift+command+space`.
    public static let all: [DeniedChordEntry] =
        [
            row([.command], .space, "Spotlight"),
            row([.option, .command], .space, "Finder search window"),
            row([.control], .space, "Previous input source"),
            row([.control, .option], .space, "Next input source"),
            row([.command], .tab, "App switcher"),
            row([.shift, .command], .tab, "App switcher, backwards"),
            row([.option, .command], .escape, "Force Quit Applications"),
            row([.control], .up, "Mission Control"),
            row([.control], .down, "Application windows"),
            row([.control], .left, "Move left a Space"),
            row([.control], .right, "Move right a Space"),
            row([.shift, .command], .digit3, "Screenshot of the screen to a file"),
            row([.shift, .command], .digit4, "Screenshot of an area to a file"),
            row([.shift, .command], .digit5, "Screenshot and recording options"),
            row([.shift, .command], .digit6, "Screenshot of the Touch Bar"),
            row([.control, .shift, .command], .digit3, "Screenshot of the screen to the clipboard"),
            row([.control, .shift, .command], .digit4, "Screenshot of an area to the clipboard"),
            row([.control, .command], .q, "Lock Screen"),
            row([.shift, .command], .q, "Log Out"),
            row([.option, .shift, .command], .q, "Log Out without confirming"),
            row([.control], .f2, "Move focus to the menu bar"),
            row([.control], .f3, "Move focus to the Dock"),
            row([.control], .f8, "Move focus to status menus"),
        ]
        + [Key.digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9].map {
            row([.control], $0, "Switch to Desktop \($0.rawValue)")
        }

    private static func row(_ modifiers: Set<Modifier>, _ key: Key, _ purpose: String) -> DeniedChordEntry {
        DeniedChordEntry(chord: Chord(modifiers, key), purpose: purpose)
    }
}
