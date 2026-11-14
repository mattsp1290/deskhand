import DeskhandCore
import Testing

private let team = TeamID("ABCDE12345")!
private let otherTeam = TeamID("ZZZZZ99999")!

private func bundle(_ raw: String) -> BundleID { BundleID(raw)! }
private func family(_ raw: String) -> BundleIDFamily { BundleIDFamily(bundle(raw)) }
private func app(_ raw: String?, _ signer: CodeSigner) -> AppIdentity {
    AppIdentity(bundleID: raw.map(bundle), signer: signer)
}

private let textEdit = app("com.apple.TextEdit", .apple)
private let editor = app("com.example.Editor", .team(team))
private let terminal = app("com.apple.Terminal", .apple)
private let deskhandID = bundle("com.example.deskhand")

/// The owners of a drag's samples, numbered from point 0.
private func owners(_ apps: AppIdentity...) -> EffectTarget {
    .pointer(windowOwners: apps.enumerated().map { WindowOwner(pointIndex: $0.offset, app: $0.element) })
}

/// Allows TextEdit and Editor, and also tries to allow two default-denied apps, which must stay denied.
private let policy = AppPolicy(
    deskhandBundleID: deskhandID,
    allowed: [
        AllowedApp(bundleID: bundle("com.apple.TextEdit"), signer: .apple),
        AllowedApp(bundleID: bundle("com.example.Editor"), signer: .team(team)),
        AllowedApp(bundleID: bundle("com.apple.Terminal"), signer: .apple),
        AllowedApp(bundleID: bundle("com.google.Chrome.canary"), signer: .team(team)),
    ])

struct RefusalCase: Sendable, CustomTestStringConvertible {
    let app: AppIdentity
    let expected: AppDenialReason?
    let testDescription: String

    init(_ description: String, _ app: AppIdentity, _ expected: AppDenialReason?) {
        self.app = app
        self.expected = expected
        testDescription = description
    }
}

struct EvaluationCase: Sendable, CustomTestStringConvertible {
    let frontmost: AppIdentity
    let target: EffectTarget
    let permittedApps: Set<BundleID>?
    let expected: AppDecision
    let testDescription: String

    init(
        _ description: String, frontmost: AppIdentity, target: EffectTarget, permitted: [String]? = nil,
        _ expected: AppDecision
    ) {
        self.frontmost = frontmost
        self.target = target
        permittedApps = permitted.map { Set($0.map(bundle)) }
        self.expected = expected
        testDescription = description
    }
}

private func deny(_ by: DeniedBy, _ subject: PolicySubject, _ reason: AppDenialReason) -> AppDecision {
    .deny(AppDenial(deniedBy: by, subject: subject, reason: reason))
}

@Suite(.timeLimit(.minutes(1))) struct AppPolicyTests {
    static let refusals: [RefusalCase] = [
        RefusalCase("Apple app on the allowlist", textEdit, nil),
        RefusalCase("team app on the allowlist", editor, nil),
        RefusalCase("Apple-allowed id signed by a team", app("com.apple.TextEdit", .team(team)), .signerMismatch),
        RefusalCase("allowed id, other team", app("com.example.Editor", .team(otherTeam)), .signerMismatch),
        RefusalCase("team-allowed id signed by Apple", app("com.example.Editor", .apple), .signerMismatch),
        RefusalCase("allowed id, unsigned", app("com.apple.TextEdit", .unsigned), .unsigned),
        RefusalCase("allowed id, signer unknown", app("com.apple.TextEdit", .unknown), .signerUnknown),
        RefusalCase("allowlist compares case exactly", app("com.example.editor", .team(team)), .notAllowlisted),
        RefusalCase("not on the allowlist", app("com.example.Other", .team(team)), .notAllowlisted),
        RefusalCase("no bundle id", app(nil, .team(team)), .unidentified),
        RefusalCase("nothing identified", .unknown, .unidentified),
        RefusalCase("deny wins over allow", terminal, .denyListed(family("com.apple.Terminal"))),
        RefusalCase("deny ignores case", app("com.apple.terminal", .apple), .denyListed(family("com.apple.Terminal"))),
        RefusalCase(
            "deny covers a nested channel", app("com.google.Chrome.canary", .team(team)),
            .denyListed(family("com.google.Chrome"))),
        RefusalCase(
            "deny covers a Safari web app", app("com.apple.Safari.WebApp.1234", .apple),
            .denyListed(family("com.apple.Safari"))),
        RefusalCase(
            "deny is reported before an unknown signer", app("com.apple.mail", .unknown),
            .denyListed(family("com.apple.mail"))),
        RefusalCase(
            "a sibling prefix is not nested", app("com.google.ChromeRemoteDesktop", .team(team)), .notAllowlisted),
    ]

    @Test(arguments: refusals)
    func refusesEachApp(_ testCase: RefusalCase) {
        #expect(policy.refusal(of: testCase.app) == testCase.expected)
    }

    static let evaluations: [EvaluationCase] = [
        EvaluationCase(
            "keyboard, allowed frontmost", frontmost: textEdit, target: .keyboard(focusOwner: textEdit), .allow),
        EvaluationCase(
            "keyboard, denied frontmost", frontmost: terminal, target: .keyboard(focusOwner: textEdit),
            deny(.policy, .frontmost, .denyListed(family("com.apple.Terminal")))),
        EvaluationCase(
            "keyboard, frontmost permitted", frontmost: textEdit, target: .keyboard(focusOwner: textEdit),
            permitted: ["com.apple.TextEdit"], .allow),
        EvaluationCase(
            "keyboard, frontmost not permitted", frontmost: textEdit, target: .keyboard(focusOwner: textEdit),
            permitted: ["com.example.Editor"], deny(.permittedApps, .frontmost, .notInPermittedApps)),
        EvaluationCase(
            "permitted_apps compares case exactly", frontmost: textEdit, target: .keyboard(focusOwner: textEdit),
            permitted: ["com.apple.textedit"], deny(.permittedApps, .frontmost, .notInPermittedApps)),
        EvaluationCase(
            "permitted_apps cannot widen the allowlist", frontmost: app("com.example.Other", .team(team)),
            target: .keyboard(focusOwner: textEdit), permitted: ["com.example.Other"],
            deny(.policy, .frontmost, .notAllowlisted)),
        EvaluationCase(
            "permitted_apps cannot override the deny list", frontmost: terminal,
            target: .keyboard(focusOwner: textEdit),
            permitted: ["com.apple.Terminal"], deny(.policy, .frontmost, .denyListed(family("com.apple.Terminal")))),
        EvaluationCase(
            "pointer, allowed owner", frontmost: textEdit, target: owners(editor), .allow),
        EvaluationCase(
            "pointer, no owners checked", frontmost: textEdit, target: .pointer(windowOwners: []),
            deny(.policy, .pointerTarget, .unidentified)),
        EvaluationCase(
            "pointer, owner unknown", frontmost: textEdit, target: owners(AppIdentity.unknown),
            deny(.policy, .windowOwner(pointIndex: 0), .unidentified)),
        EvaluationCase(
            "pointer, owner signer unknown", frontmost: textEdit,
            target: owners(app("com.example.Editor", .unknown)),
            deny(.policy, .windowOwner(pointIndex: 0), .signerUnknown)),
        EvaluationCase(
            "drag, last point over a denied app", frontmost: textEdit,
            target: owners(editor, terminal),
            deny(.policy, .windowOwner(pointIndex: 1), .denyListed(family("com.apple.Terminal")))),
        EvaluationCase(
            "pointer, frontmost denied before owner", frontmost: terminal, target: owners(AppIdentity.unknown),
            deny(.policy, .frontmost, .denyListed(family("com.apple.Terminal")))),
        EvaluationCase(
            "pointer, owner not permitted", frontmost: textEdit, target: owners(editor),
            permitted: ["com.apple.TextEdit"], deny(.permittedApps, .windowOwner(pointIndex: 0), .notInPermittedApps)),
        EvaluationCase(
            "pointer, both permitted", frontmost: textEdit, target: owners(editor, textEdit),
            permitted: ["com.apple.TextEdit", "com.example.Editor"], .allow),
        EvaluationCase(
            "policy refusal outranks a permitted_apps refusal", frontmost: textEdit,
            target: owners(app("com.example.Other", .team(team))), permitted: ["com.example.Editor"],
            deny(.policy, .windowOwner(pointIndex: 0), .notAllowlisted)),
    ]

    @Test(arguments: evaluations)
    func evaluatesEachCheck(_ testCase: EvaluationCase) {
        let decision = policy.evaluate(
            frontmost: testCase.frontmost, target: testCase.target, permittedApps: testCase.permittedApps)
        #expect(decision == testCase.expected)
    }

    @Test func deniesEveryAppByDefault() {
        let empty = AppPolicy(deskhandBundleID: deskhandID)
        #expect(empty.allowed.isEmpty)
        for candidate in [textEdit, editor, app("com.apple.finder", .apple)] {
            #expect(empty.refusal(of: candidate) == .notAllowlisted)
            #expect(
                empty.evaluate(frontmost: candidate, target: .keyboard(focusOwner: textEdit), permittedApps: nil)
                    == deny(.policy, .frontmost, .notAllowlisted))
        }
    }

    @Test func aDenialBecomesDeniedAppWithMeasured() {
        let measured = Measured(
            frontmostApp: AppRef(bundleID: "com.apple.Terminal", teamID: nil, name: "Terminal"), targetApp: nil,
            windowTitle: nil, globalPoint: nil, measuredAt: Timestamp(millisecondsSinceEpoch: 0))
        let denial = AppDenial(deniedBy: .permittedApps, subject: .frontmost, reason: .notInPermittedApps)
        let reason = denial.toolErrorReason(measured: measured)
        #expect(reason == .deniedApp(.permittedApps, measured: measured, pointIndex: nil))
        #expect(reason.code == .deniedApp)
    }

    /// Contract 6.9: deskhand's own bundle is never allowed, whatever the configuration says, as the
    /// frontmost app, a window owner or the owner of keyboard focus.
    @Test func deskhandItselfIsAlwaysDenied() {
        let me = app("com.example.deskhand", .team(team))
        let helper = app("com.example.deskhand.indicator", .team(team))
        let configured = AppPolicy(
            deskhandBundleID: deskhandID,
            allowed: [
                AllowedApp(bundleID: deskhandID, signer: .team(team)),
                AllowedApp(bundleID: bundle("com.apple.TextEdit"), signer: .apple),
            ],
            denied: [])
        #expect(configured.refusal(of: me) == .deskhandItself)
        #expect(configured.refusal(of: helper) == .deskhandItself)
        #expect(
            configured.evaluate(frontmost: me, target: .keyboard(focusOwner: textEdit), permittedApps: nil)
                == deny(.policy, .frontmost, .deskhandItself))
        #expect(
            configured.evaluate(frontmost: textEdit, target: .keyboard(focusOwner: me), permittedApps: nil)
                == deny(.policy, .keyboardFocus, .deskhandItself))
        #expect(
            configured.evaluate(frontmost: textEdit, target: owners(textEdit, me), permittedApps: nil)
                == deny(.policy, .windowOwner(pointIndex: 1), .deskhandItself))
        #expect(configured.excludesFromCapture(deskhandID))
    }

    /// Contract 6.9: a panel of another process can take keystrokes while the frontmost app stays
    /// the same, so keyboard focus is checked too, and an unreadable focus refuses.
    @Test func keyboardChecksTheOwnerOfFocus() {
        let spotlight = app("com.apple.Spotlight", .apple)
        #expect(
            policy.evaluate(frontmost: textEdit, target: .keyboard(focusOwner: spotlight), permittedApps: nil)
                == deny(.policy, .keyboardFocus, .notAllowlisted))
        #expect(
            policy.evaluate(frontmost: textEdit, target: .keyboard(focusOwner: .unknown), permittedApps: nil)
                == deny(.policy, .keyboardFocus, .unidentified))
        #expect(
            policy.evaluate(
                frontmost: textEdit, target: .keyboard(focusOwner: editor),
                permittedApps: [bundle("com.apple.TextEdit")])
                == deny(.permittedApps, .keyboardFocus, .notInPermittedApps))
    }

    /// `details.point_index` names the point whose owner refused, 0 when nothing was checked, and is
    /// absent for the frontmost app and keyboard focus.
    @Test func aDenialNamesThePointThatCausedIt() {
        let measured = Measured(
            frontmostApp: AppRef(textEdit, name: "TextEdit"), targetApp: nil, windowTitle: "secret",
            globalPoint: nil, measuredAt: Timestamp(millisecondsSinceEpoch: 0))
        let cases: [(PolicySubject, Int?)] = [
            (.frontmost, nil), (.keyboardFocus, nil), (.pointerTarget, 0), (.windowOwner(pointIndex: 4), 4),
        ]
        for (subject, index) in cases {
            let reason = AppDenial(deniedBy: .policy, subject: subject, reason: .unidentified).toolErrorReason(
                measured: measured)
            #expect(reason == .deniedApp(.policy, measured: measured, pointIndex: index))
        }
    }

    /// Contract 6.7: a title of an app on the capture exclusion list, of deskhand, or of an app that
    /// is not identified never becomes a title `measured` can carry.
    @Test func titlesOfHiddenAppsAreRemoved() {
        let mail = AppRef(bundleID: "com.apple.mail", teamID: nil, name: "Mail")
        let edit = AppRef(textEdit, name: "TextEdit")
        let deskhand = AppRef(bundleID: "com.example.deskhand", teamID: nil, name: "deskhand")
        #expect(policy.windowTitle("Inbox", of: mail) == nil)
        #expect(policy.windowTitle("Arm", of: deskhand) == nil)
        #expect(policy.windowTitle("Untitled", of: .undetermined) == nil)
        #expect(policy.windowTitle("Untitled", of: nil) == nil)
        #expect(policy.windowTitle(nil, of: edit) == nil)
        #expect(policy.windowTitle("notes.txt", of: edit) == "notes.txt")
    }

    /// Contract 6.9, "Drag": every point of the path is checked, consecutive samples are at most
    /// 8 frame pixels apart, and each names the point that ends its segment.
    @Test func aDragIsSampledAlongItsWholePath() throws {
        let drag = try PointerArguments(arguments: [
            "holder_id": "h", "frame_id": "f", "operation_id": "o",
            "action": [
                "type": "drag",
                "path": [["x": 300, "y": 400], ["x": 520, "y": 400], ["x": 520, "y": 640], ["x": 523, "y": 641]],
            ],
        ]).action
        let samples = drag.policySamples
        #expect(samples.first?.pointIndex == 0 && samples.first?.point == FramePoint(x: 300, y: 400))
        #expect(samples.last?.pointIndex == 3 && samples.last?.point == FramePoint(x: 523, y: 641))
        for point in drag.points { #expect(samples.contains { $0.point == point }) }
        for (previous, next) in zip(samples, samples.dropFirst()) {
            let dx = Double(next.point.x - previous.point.x)
            let dy = Double(next.point.y - previous.point.y)
            #expect((dx * dx + dy * dy).squareRoot() <= Double(ContractConstants.dragPolicySamplePx))
            #expect(next.pointIndex >= previous.pointIndex)
        }
        #expect(samples.filter { $0.pointIndex == 1 }.last?.point == FramePoint(x: 520, y: 400))
        let move = try PointerArguments(arguments: [
            "holder_id": "h", "frame_id": "f", "operation_id": "o", "action": ["type": "move", "x": 5, "y": 6],
        ]).action
        #expect(move.policySamples.map(\.point) == [FramePoint(x: 5, y: 6)])
        let hold = try PointerArguments(arguments: [
            "holder_id": "h", "frame_id": "f", "operation_id": "o",
            "action": ["type": "drag", "path": [["x": 9, "y": 9], ["x": 9, "y": 9]]],
        ]).action
        #expect(hold.policySamples.map(\.pointIndex) == [0, 1])
    }

    @Test func anEmptyDenyListStillDeniesByDefault() {
        let open = AppPolicy(
            deskhandBundleID: deskhandID, allowed: [AllowedApp(bundleID: bundle("com.apple.Terminal"), signer: .apple)],
            denied: [])
        #expect(open.refusal(of: terminal) == nil)
        #expect(open.refusal(of: app("com.apple.Safari", .apple)) == .notAllowlisted)
    }
}

@Suite(.timeLimit(.minutes(1))) struct AppIdentityTests {
    @Test(arguments: ["ABCDE12345", "0123456789", "EQHXZ8M8AV"])
    func acceptsTeamIDs(_ raw: String) {
        #expect(TeamID(raw)?.rawValue == raw)
    }

    @Test(arguments: ["", "ABCDE1234", "ABCDE123456", "abcde12345", "ABCDE-1234", "ABCDE1234\n", "ABCDE 1234"])
    func refusesMalformedTeamIDs(_ raw: String) {
        #expect(TeamID(raw) == nil)
    }

    @Test func onlyATeamSignerHasATeamIdentifier() {
        #expect(CodeSigner.team(team).teamIdentifier == "ABCDE12345")
        #expect(CodeSigner.apple.teamIdentifier == nil)
        #expect(CodeSigner.unsigned.teamIdentifier == nil)
        #expect(CodeSigner.unknown.teamIdentifier == nil)
    }

    @Test(arguments: [
        ("com.google.Chrome", true), ("com.google.Chrome.canary", true), ("COM.GOOGLE.CHROME", true),
        ("com.google.chrome.app.abcdef", true), ("com.google.ChromeRemoteDesktop", false), ("com.google", false),
        ("org.google.Chrome", false),
    ])
    func familyCoversNestedIdentifiers(_ raw: String, _ expected: Bool) {
        #expect(family("com.google.Chrome").contains(bundle(raw)) == expected)
    }

    @Test func familiesCompareIgnoringCase() {
        #expect(family("com.apple.Terminal") == family("COM.apple.terminal"))
        #expect(Set([family("com.apple.Terminal"), family("com.apple.terminal")]).count == 1)
    }
}
