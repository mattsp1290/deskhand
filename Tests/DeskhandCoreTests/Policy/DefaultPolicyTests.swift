import DeskhandCore
import Testing

private func bundle(_ raw: String) -> BundleID { BundleID(raw)! }
private let standard = AppPolicy(deskhandBundleID: BundleID("com.example.deskhand")!)

@Suite(.timeLimit(.minutes(1))) struct DefaultDenyListTests {
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
        let decision = standard.refusal(of: AppIdentity(bundleID: bundle(raw), signer: .apple))
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

    @Test(arguments: [
        ("com.apple.Terminal", true), ("com.googlecode.iterm2", true), ("com.apple.keychainaccess", true),
        ("com.1password.1password", true), ("com.apple.mail", true), ("com.apple.MobileSMS", true),
        ("com.tinyspeck.slackmacgap", true), ("com.apple.Safari", false), ("com.google.Chrome", false),
        ("com.apple.systempreferences", false), ("com.apple.TextEdit", false),
    ])
    func captureExclusionsByDefault(_ raw: String, _ excluded: Bool) {
        #expect(standard.excludesFromCapture(bundle(raw)) == excluded)
    }

    @Test func captureExclusionsAreConfigurable() {
        let policy = AppPolicy(
            deskhandBundleID: bundle("com.example.deskhand"),
            captureExclusions: [BundleIDFamily(bundle("com.example.Secret"))])
        #expect(policy.excludesFromCapture(bundle("com.example.Secret")))
        #expect(policy.excludesFromCapture(bundle("com.example.secret.helper")))
        #expect(!policy.excludesFromCapture(bundle("com.apple.keychainaccess")))
        #expect(!standard.excludesFromCapture(bundle("com.apple.TextEdit")))
        #expect(standard.excludesFromCapture(bundle("com.1password.1password")))
    }
}

@Suite(.timeLimit(.minutes(1))) struct DeniedChordTests {
    static let contractList: [String] = [
        "command+space", "control+space", "command+tab", "option+command+escape", "control+up", "control+down",
        "control+left", "control+right", "control+1", "control+2", "control+3", "control+4", "control+5",
        "control+6", "control+7", "control+8", "control+9", "shift+command+3", "shift+command+4", "shift+command+5",
        "shift+command+6", "control+f1",
        "control+f2", "control+f3", "control+f4", "control+f5", "control+f6", "control+f7", "control+f8", "f11",
        "command+f5", "option+command+8", "control+command+q", "shift+command+q",
    ]

    @Test func theDefaultListIsTheContractList() {
        #expect(DeniedChordEntry.all.map(\.chord.shortcut).sorted() == Self.contractList.sorted())
        #expect(AppPolicy.defaultDeniedChords.count == Self.contractList.count)
    }

    static let denied: [(Chord, String)] = [
        (Chord([.command], .space), "command+space"),
        (Chord([.command], .tab), "command+tab"),
        (Chord([.command, .option], .escape), "option+command+escape"),
        (Chord([.control], .left), "control+left"),
        (Chord([.command, .shift], .digit4), "shift+command+4"),
        (Chord([.command, .shift], .digit6), "shift+command+6"),
        (Chord([.control], .digit1), "control+1"),
        (Chord([.control], .digit9), "control+9"),
        (Chord([.control], .f2), "control+f2"),
        (Chord([.control], .f3), "control+f3"),
        (Chord([.control], .f8), "control+f8"),
        (Chord([], .f11), "f11"),
        (Chord([.command], .f5), "command+f5"),
        (Chord([.command, .shift], .tab), "shift+command+tab"),
        (Chord([.command, .shift, .control], .digit4), "control+shift+command+4"),
        (Chord([.command, .shift], .space), "shift+command+space"),
        (Chord([.command, .option], .space), "option+command+space"),
        (Chord([.option, .command], .f5), "option+command+f5"),
        (Chord([.shift], .f11), "shift+f11"),
        (Chord([.option, .shift, .command], .q), "option+shift+command+q"),
        (Chord([.control, .shift], .digit2), "control+shift+2"),
        (Chord([.control, .shift, .command], .digit6), "control+shift+command+6"),
    ]

    @Test(arguments: denied)
    func deniesListedChordsAndTheirSupersets(_ chord: Chord, _ shortcut: String) {
        let decision = standard.evaluate(chord: chord)
        #expect(decision == .deny(chord))
        #expect(decision.toolErrorReason == .deniedShortcut(shortcut: shortcut))
        #expect(decision.toolErrorReason?.code == .deniedShortcut)
    }

    @Test(arguments: [
        Chord([.command], .c), Chord([.command], .v), Chord([], .space), Chord([], .tab), Chord([], .left),
        Chord([.option], .left), Chord([.command], .digit3), Chord([.control], .a), Chord([], .f5),
        Chord([.shift], .tab), Chord([.option], .space), Chord([], .q), Chord([], .digit1), Chord([.command], .digit1),
        Chord([.shift], .digit6), Chord([.control], .digit0),
    ])
    func allowsOtherChords(_ chord: Chord) {
        #expect(standard.evaluate(chord: chord) == .allow)
        #expect(standard.evaluate(chord: chord).toolErrorReason == nil)
    }

    @Test func theDeniedSetIsConfigurable() {
        let custom = AppPolicy(deskhandBundleID: bundle("com.example.deskhand"), deniedChords: [Chord([.command], .w)])
        #expect(custom.evaluate(chord: Chord([.command], .space)) == .allow)
        #expect(custom.evaluate(chord: Chord([.command], .w)) == .deny(Chord([.command], .w)))
        #expect(custom.evaluate(chord: Chord([.command, .shift], .w)) == .deny(Chord([.command, .shift], .w)))
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
        #expect(standard.evaluate(chord: chord) == .deny(Chord([.option, .command], .space)))
    }
}
