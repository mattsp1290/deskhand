import DeskhandCore
import Testing

private func bundle(_ raw: String) -> BundleID { BundleID(raw)! }

@Suite struct DefaultDenyListTests {
    /// The apps the bean and the plan name, each with the category it must be denied under.
    static let required: [(String, SensitiveAppCategory)] = [
        ("com.apple.Terminal", .terminal), ("com.googlecode.iterm2", .terminal),
        ("com.apple.systempreferences", .systemSettings), ("com.apple.keychainaccess", .keychain),
        ("com.1password.1password", .passwordManager), ("com.bitwarden.desktop", .passwordManager),
        ("com.apple.mail", .mail), ("com.apple.MobileSMS", .messaging), ("com.tinyspeck.slackmacgap", .messaging),
        ("com.hnc.Discord", .messaging), ("com.apple.Safari", .browser), ("com.google.Chrome", .browser),
        ("org.mozilla.firefox", .browser), ("company.thebrowser.Browser", .browser),
        ("com.microsoft.edgemac", .browser), ("com.brave.Browser", .browser),
    ]

    @Test(arguments: required)
    func deniesEachNamedApp(_ raw: String, _ category: SensitiveAppCategory) {
        let entry = DefaultDenyEntry.all.first { $0.family.contains(bundle(raw)) }
        #expect(entry?.category == category)
        #expect(entry?.confidence == .known)
        let decision = AppPolicy().refusal(of: AppIdentity(bundleID: bundle(raw), signer: .apple))
        #expect(decision == .denyListed(BundleIDFamily(bundle(raw))))
    }

    @Test(arguments: ["com.google.Chrome.beta", "com.microsoft.edgemac.Canary", "com.brave.Browser.nightly"])
    func deniesBrowserChannels(_ raw: String) {
        #expect(AppPolicy.defaultDenied.contains { $0.contains(bundle(raw)) })
    }

    @Test func everyCategoryHasAnEntryAndNoEntryRepeats() {
        let categories = Set(DefaultDenyEntry.all.map(\.category))
        #expect(categories == Set(SensitiveAppCategory.allCases))
        #expect(AppPolicy.defaultDenied.count == DefaultDenyEntry.all.count)
    }

    @Test func noDefaultEntryIsNestedInAnother() {
        for outer in DefaultDenyEntry.all {
            for inner in DefaultDenyEntry.all where inner.family != outer.family {
                #expect(!outer.family.contains(inner.family.root), "\(outer.family) covers \(inner.family)")
            }
        }
    }

    @Test(arguments: SensitiveAppCategory.allCases)
    func captureExclusionsFollowTheCategory(_ category: SensitiveAppCategory) {
        let policy = AppPolicy()
        for entry in DefaultDenyEntry.all where entry.category == category {
            #expect(policy.excludesFromCapture(entry.family.root) == category.excludedFromCaptureByDefault)
        }
    }

    @Test func captureExclusionsAreConfigurable() {
        let policy = AppPolicy(captureExclusions: [BundleIDFamily(bundle("com.example.Secret"))])
        #expect(policy.excludesFromCapture(bundle("com.example.Secret")))
        #expect(policy.excludesFromCapture(bundle("com.example.secret.helper")))
        #expect(!policy.excludesFromCapture(bundle("com.apple.keychainaccess")))
        #expect(!AppPolicy().excludesFromCapture(bundle("com.apple.TextEdit")))
        #expect(AppPolicy().excludesFromCapture(bundle("com.1password.1password")))
    }
}

@Suite struct DeniedChordTests {
    /// The chords the bean and the plan name, spelled as `details.shortcut`.
    static let required: [(Chord, String)] = [
        (Chord([.command], .space), "command+space"),
        (Chord([.command], .tab), "command+tab"),
        (Chord([.command, .option], .escape), "option+command+escape"),
        (Chord([.control], .left), "control+left"),
        (Chord([.control], .right), "control+right"),
        (Chord([.control], .up), "control+up"),
        (Chord([.control], .down), "control+down"),
        (Chord([.command, .shift], .digit3), "shift+command+3"),
        (Chord([.command, .shift], .digit4), "shift+command+4"),
        (Chord([.command, .shift], .digit5), "shift+command+5"),
        (Chord([.command, .shift, .control], .digit4), "control+shift+command+4"),
    ]

    @Test(arguments: required)
    func deniesEachNamedChord(_ chord: Chord, _ shortcut: String) {
        let decision = AppPolicy().evaluate(chord: chord)
        #expect(decision == .deny(chord))
        #expect(decision.toolErrorReason == .deniedShortcut(shortcut: shortcut))
        #expect(decision.toolErrorReason?.code == .deniedShortcut)
    }

    @Test func deniesEveryDefaultEntry() {
        #expect(AppPolicy.defaultDeniedChords.count == DeniedChordEntry.all.count)
        for entry in DeniedChordEntry.all {
            #expect(AppPolicy().evaluate(chord: entry.chord) == .deny(entry.chord), "\(entry.purpose)")
        }
    }

    @Test(arguments: [
        Chord([.command], .c), Chord([.command], .v), Chord([.command, .shift], .space), Chord([], .space),
        Chord([], .tab), Chord([], .left), Chord([.option], .left), Chord([.command], .digit3), Chord([.control], .a),
    ])
    func allowsOtherChords(_ chord: Chord) {
        #expect(AppPolicy().evaluate(chord: chord) == .allow)
        #expect(AppPolicy().evaluate(chord: chord).toolErrorReason == nil)
    }

    @Test func theDeniedSetIsConfigurable() {
        let custom = AppPolicy(deniedChords: [Chord([.command], .w)])
        #expect(custom.evaluate(chord: Chord([.command], .space)) == .allow)
        #expect(custom.evaluate(chord: Chord([.command], .w)) == .deny(Chord([.command], .w)))
    }

    @Test func aDecodedPressSpellsItsChordTheSameWay() throws {
        let arguments: JSONObject = [
            "holder_id": "h", "frame_id": "frm_x", "operation_id": "o",
            "action": ["type": "press", "key": "space", "modifiers": ["command", "option"]],
        ]
        guard case .press(let press) = try KeyboardArguments(arguments: arguments).action else {
            Issue.record("expected a press")
            return
        }
        let chord = Chord(press)
        #expect(chord.shortcut == press.shortcut)
        #expect(AppPolicy().evaluate(chord: chord) == .deny(Chord([.option, .command], .space)))
    }
}
