import DeskhandCore
import DeskhandPlatform
import Testing

private let team = IdentityFixtures.team

struct SignatureCase: Sendable, CustomTestStringConvertible {
    let lookup: CodeSignatureLookup
    let signer: CodeSigner
    let bundleID: String?
    let uncertainty: IdentityUncertainty?
    let testDescription: String

    init(
        _ description: String, _ lookup: CodeSignatureLookup, _ signer: CodeSigner, _ bundleID: String?,
        _ uncertainty: IdentityUncertainty?
    ) {
        self.lookup = lookup
        self.signer = signer
        self.bundleID = bundleID
        self.uncertainty = uncertainty
        testDescription = description
    }
}

private func facts(
    _ validity: CodeSignatureFacts.Validity, adHoc: Bool = false, apple: Bool = false, team: String? = nil,
    sealed: String? = nil, atPath: String? = nil
) -> CodeSignatureLookup {
    .found(
        CodeSignatureFacts(
            validity: validity, isAdHoc: adHoc, satisfiesAppleAnchor: apple, teamIdentifier: team,
            sealedBundleIdentifier: sealed, bundleIdentifierAtPath: atPath))
}

private let signatureCases: [SignatureCase] = [
    SignatureCase(
        "team signed", facts(.valid, team: "ABCDE12345", sealed: "com.example.Editor"), .team(team),
        "com.example.Editor", nil),
    SignatureCase(
        "Apple platform app", facts(.valid, apple: true, sealed: "com.apple.TextEdit"), .apple, "com.apple.TextEdit",
        nil),
    SignatureCase(
        "Apple anchor wins over a team identifier",
        facts(.valid, apple: true, team: "ABCDE12345", sealed: "com.apple.X"),
        .apple, "com.apple.X", nil),
    SignatureCase(
        "process gone", .processGone, .unknown, nil, .processGone),
    SignatureCase("signature unreadable", .unreadable(-67_062), .unknown, nil, .signatureUnreadable(-67_062)),
    SignatureCase(
        "unsigned names the bundle on disk", facts(.unsigned, atPath: "com.example.Tool"), .unsigned,
        "com.example.Tool", .signatureNotTrusted),
    SignatureCase(
        "invalid signature", facts(.invalid, team: "ABCDE12345", sealed: "com.example.Editor"), .unsigned,
        "com.example.Editor", .signatureNotTrusted),
    SignatureCase(
        "ad hoc", facts(.valid, adHoc: true, sealed: "com.example.Editor"), .unsigned, "com.example.Editor",
        .signatureNotTrusted),
    SignatureCase(
        "valid but neither team nor Apple", facts(.valid, sealed: "com.example.Editor"), .unsigned,
        "com.example.Editor", .signatureNotTrusted),
    SignatureCase(
        "malformed team identifier", facts(.valid, team: "abcde12345", sealed: "com.example.Editor"), .unknown,
        "com.example.Editor", .malformedTeamIdentifier),
    SignatureCase(
        "trusted signer ignores the unsealed bundle on disk",
        facts(.valid, team: "ABCDE12345", atPath: "com.example.Editor"), .team(team), nil, .noBundleID),
    SignatureCase(
        "trusted signer with no Info.plist", facts(.valid, team: "ABCDE12345"), .team(team), nil, .noBundleID),
    SignatureCase(
        "bundle identifier outside the alphabet", facts(.valid, team: "ABCDE12345", sealed: "com.example/Editor"),
        .team(team), nil, .noBundleID),
]

@Suite struct MeasuredAppTests {
    @Test(arguments: signatureCases)
    func mapsSignatureToIdentity(_ testCase: SignatureCase) {
        let app = MeasuredApp(pid: 42, signature: testCase.lookup, name: "Editor")
        #expect(app.identity.signer == testCase.signer)
        #expect(app.identity.bundleID?.rawValue == testCase.bundleID)
        #expect(app.uncertainty == testCase.uncertainty)
        #expect(app.pid == 42)
    }

    /// Whatever the uncertainty, the policy must refuse, even one that allows every bundle identifier
    /// in the table under every signer.
    @Test(arguments: signatureCases)
    func uncertainIdentityIsAlwaysRefused(_ testCase: SignatureCase) {
        let app = MeasuredApp(pid: 42, signature: testCase.lookup, name: nil)
        let bundleIDs = signatureCases.compactMap { $0.bundleID.flatMap(BundleID.init) }
        let allowed = Set(
            bundleIDs.flatMap { id in
                [AllowedApp(bundleID: id, signer: .apple), AllowedApp(bundleID: id, signer: .team(team))]
            })
        let policy = AppPolicy(allowed: allowed, denied: [])
        #expect((policy.refusal(of: app.identity) == nil) == app.isCertain)
    }

    @Test(arguments: [
        IdentityUncertainty.noFrontmostApp, .noFocusedApp, .accessibilityUntrusted, .focusUnreadable(-25_204),
        .windowListUnavailable, .noWindow, .windowUnreadable, .noOwnerProcess,
    ])
    func unidentifiedAppIsUnknown(_ reason: IdentityUncertainty) {
        let app = MeasuredApp.unidentified(reason)
        #expect(app.identity == .unknown)
        #expect(app.uncertainty == reason)
        #expect(!app.isCertain)
        #expect(AppPolicy().refusal(of: app.identity) == .unidentified)
        #expect(app.appRef == AppRef(bundleID: nil, teamID: nil, name: ""))
    }

    @Test func appRefCarriesBundleTeamAndName() {
        let app = MeasuredApp(pid: 7, signature: IdentityFixtures.teamSigned("com.example.Editor"), name: "Editor")
        #expect(app.appRef == AppRef(bundleID: "com.example.Editor", teamID: "ABCDE12345", name: "Editor"))
        let apple = MeasuredApp(pid: 8, signature: IdentityFixtures.appleSigned("com.apple.TextEdit"), name: nil)
        #expect(apple.appRef == AppRef(bundleID: "com.apple.TextEdit", teamID: nil, name: "com.apple.TextEdit"))
    }
}
