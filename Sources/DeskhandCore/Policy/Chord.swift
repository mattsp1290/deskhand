/// A key together with the exact set of modifiers held while it is pressed. A bare key has no
/// modifiers.
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
    /// The default denied global shortcut list of contract 6.9, exactly: shortcuts that reach past
    /// the frontmost app, and those that move keyboard focus to the menu bar, the Dock or a status
    /// menu, where deskhand's own menu is. ``AppPolicy/evaluate(chord:)`` also denies every press
    /// that adds modifiers to an entry, so `shift+command+tab` and `control+shift+command+4` need no
    /// rows of their own, and `f11` denies the bare key.
    public static let all: [DeniedChordEntry] =
        [
            row([.command], .space, "Spotlight"),
            row([.control], .space, "Input source switching"),
            row([.command], .tab, "Switch app"),
            row([.option, .command], .escape, "Force Quit"),
            row([.control], .up, "Mission Control"),
            row([.control], .down, "Application windows"),
            row([.control], .left, "Move left a Space"),
            row([.control], .right, "Move right a Space"),
            row([.shift, .command], .digit3, "Screenshot of the screen"),
            row([.shift, .command], .digit4, "Screenshot of an area"),
            row([.shift, .command], .digit5, "Screenshot and recording options"),
        ]
        + zip([Key.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8], focusPurposes).map { row([.control], $0, $1) }
        + [
            row([], .f11, "Show Desktop"),
            row([.command], .f5, "VoiceOver"),
            row([.option, .command], .digit8, "Zoom"),
            row([.control, .command], .q, "Lock Screen"),
            row([.shift, .command], .q, "Log Out"),
        ]

    private static let focusPurposes = [
        "Turn keyboard access on or off", "Move focus to the menu bar", "Move focus to the Dock",
        "Move focus to the active or next window", "Move focus to the window toolbar",
        "Move focus to the floating window", "Change the way Tab moves focus", "Move focus to the status menus",
    ]

    private static func row(_ modifiers: Set<Modifier>, _ key: Key, _ purpose: String) -> DeniedChordEntry {
        DeniedChordEntry(chord: Chord(modifiers, key), purpose: purpose)
    }
}
