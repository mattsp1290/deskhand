import CoreGraphics
import DeskhandCore
import DeskhandPlatform
import Testing

private typealias F = IdentityFixtures

private let editorPID: pid_t = 100
private let viewerPID: pid_t = 200
private let windowServerPID: pid_t = 300
private let dockPID: pid_t = 400

private let signatures: [pid_t: CodeSignatureLookup] = [
    editorPID: F.teamSigned("com.example.Editor"),
    viewerPID: F.appleSigned("com.apple.Preview"),
    windowServerPID: F.appleSigned("com.apple.WindowServer"),
    dockPID: F.appleSigned("com.apple.dock"),
]

private let cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))
private let draggingLayer = Int(CGWindowLevelForKey(.draggingWindow))

/// Front to back: the pointer, the menu bar, the Dock, then Editor over Preview on a display to the
/// left of the main one (negative x).
private let desktop: [IdentityWindowEntry] = [
    F.window(pid: windowServerPID, layer: cursorLayer, 95, 95, 28, 40),
    F.window(pid: windowServerPID, layer: 24, -1000, 0, 2512, 33, title: "Menubar"),
    F.window(pid: dockPID, layer: 20, 200, 900, 600, 80),
    F.window(pid: editorPID, -800, 100, 1000, 500, title: "notes.txt", owner: "Editor"),
    F.window(pid: viewerPID, -1000, 50, 2000, 800, title: "scan.pdf"),
]

private func probe(_ system: FakeIdentitySystem) -> IdentityProbe { IdentityProbe(system: system) }

private func owner(at x: Double, _ y: Double, in windows: [IdentityWindowEntry]) -> WindowOwnerHit {
    probe(FakeIdentitySystem(windows: windows, signatures: signatures)).windowOwner(at: GlobalPoint(x: x, y: y))
}

@Suite struct WindowOwnerTests {
    @Test func normalWindowsAreHitFrontToBack() {
        let editor = owner(at: -500, 300, in: desktop)
        #expect(editor.owner.identity.bundleID?.rawValue == "com.example.Editor")
        #expect(editor.owner.isCertain)
        #expect(editor.title == "notes.txt")
        #expect(editor.layer == 0)
        let viewer = owner(at: 500, 700, in: desktop)
        #expect(viewer.owner.identity.bundleID?.rawValue == "com.apple.Preview")
        #expect(viewer.title == "scan.pdf")
    }

    @Test func menuBarAndDockOwnTheirArea() {
        let menuBar = owner(at: -500, 10, in: desktop)
        #expect(menuBar.owner.identity.bundleID?.rawValue == "com.apple.WindowServer")
        #expect(menuBar.layer == 24)
        let dock = owner(at: 300, 950, in: desktop)
        #expect(dock.owner.identity.bundleID?.rawValue == "com.apple.dock")
        #expect(dock.layer == 20)
    }

    @Test func pointerAndDragImageAreLookedThrough() {
        #expect(owner(at: 100, 100, in: desktop).owner.identity.bundleID?.rawValue == "com.example.Editor")
        let dragImage = F.window(pid: windowServerPID, layer: draggingLayer, 0, 0, 3000, 3000)
        #expect(
            owner(at: 100, 100, in: [dragImage] + desktop).owner.identity.bundleID?.rawValue == "com.example.Editor")
    }

    @Test func overlayAboveNormalLevelOwnsThePoint() {
        let lockScreen = F.window(pid: windowServerPID, layer: 2001, -15_000, -15_000, 30_000, 30_000)
        #expect(
            owner(at: -500, 300, in: [lockScreen] + desktop).owner.identity.bundleID?.rawValue
                == "com.apple.WindowServer")
    }

    @Test func windowBelowNormalLevelStillCounts() {
        let low = F.window(pid: editorPID, layer: -1, 5000, 0, 100, 100)
        #expect(owner(at: 5050, 50, in: desktop + [low]).owner.identity.bundleID?.rawValue == "com.example.Editor")
    }

    @Test func unreadableLevelCounts() {
        let unknownLevel = F.window(pid: dockPID, layer: nil, 0, 0, 10, 10)
        #expect(owner(at: 5, 5, in: [unknownLevel] + desktop).owner.identity.bundleID?.rawValue == "com.apple.dock")
    }

    @Test(arguments: [
        (-800.0, 100.0, "com.example.Editor"), (199.999, 599.999, "com.example.Editor"),
        (200.0, 300.0, "com.apple.Preview"), (-500.0, 600.0, "com.apple.Preview"),
    ])
    func edgesAreHalfOpen(x: Double, y: Double, expected: String) {
        #expect(owner(at: x, y, in: desktop).owner.identity.bundleID?.rawValue == expected)
    }

    @Test func noWindowIsUncertain() {
        let hit = owner(at: 5000, 5000, in: desktop)
        #expect(hit.owner.uncertainty == .noWindow)
        #expect(hit.owner.identity == .unknown)
        #expect(hit.title == nil)
        #expect(hit.layer == nil)
    }

    @Test func unreadableFrameInFrontIsUncertain() {
        let blank = IdentityWindowEntry(ownerPID: dockPID, layer: 0, bounds: nil)
        #expect(owner(at: -500, 300, in: [blank] + desktop).owner.uncertainty == .windowUnreadable)
        #expect(owner(at: -500, 300, in: desktop + [blank]).owner.isCertain)
    }

    @Test func windowWithoutOwnerIsUncertain() {
        let orphan = F.window(pid: nil, 0, 0, 10, 10, title: "x", owner: "Ghost")
        let hit = owner(at: 5, 5, in: [orphan])
        #expect(hit.owner.uncertainty == .noOwnerProcess)
        #expect(hit.owner.name == "Ghost")
        #expect(hit.title == "x")
    }

    @Test func ownerThatExitedIsUncertain() {
        let gone = F.window(pid: 999, 0, 0, 10, 10, owner: "Gone")
        let hit = owner(at: 5, 5, in: [gone])
        #expect(hit.owner.uncertainty == .processGone)
        #expect(hit.owner.identity == .unknown)
        #expect(hit.owner.name == "Gone")
    }

    @Test func missingWindowListMakesEveryPointUncertain() {
        let system = FakeIdentitySystem(windows: nil, signatures: signatures)
        let hits = probe(system).windowOwners(at: [GlobalPoint(x: 0, y: 0), GlobalPoint(x: 1, y: 1)])
        #expect(hits.map(\.owner.uncertainty) == [.windowListUnavailable, .windowListUnavailable])
        #expect(hits.map(\.point) == [GlobalPoint(x: 0, y: 0), GlobalPoint(x: 1, y: 1)])
    }

    @Test func dragPathIsSampledInOrderWithOneLookupPerOwner() {
        let system = FakeIdentitySystem(windows: desktop, signatures: signatures)
        let path = [
            GlobalPoint(x: -500, y: 300), GlobalPoint(x: -100, y: 300), GlobalPoint(x: 300, y: 300),
            GlobalPoint(x: 300, y: 950), GlobalPoint(x: 9000, y: 0),
        ]
        let hits = probe(system).windowOwners(at: path)
        #expect(hits.map(\.point) == path)
        #expect(
            hits.map(\.owner.identity.bundleID?.rawValue) == [
                "com.example.Editor", "com.example.Editor", "com.apple.Preview", "com.apple.dock", nil,
            ])
        #expect(system.signatureLookups(of: editorPID) == 1)
        #expect(system.signatureLookups(of: viewerPID) == 1)
        #expect(probe(system).windowOwners(at: []).isEmpty)
    }

    @Test func nameFallsBackFromAppNameToOwnerNameToBundleID() {
        let windows = [F.window(pid: editorPID, 0, 0, 10, 10, owner: "editor-proc")]
        let named = FakeIdentitySystem(windows: windows, signatures: signatures, names: [editorPID: "Editor"])
        #expect(probe(named).windowOwner(at: GlobalPoint(x: 1, y: 1)).owner.name == "Editor")
        let unnamed = FakeIdentitySystem(windows: windows, signatures: signatures)
        #expect(probe(unnamed).windowOwner(at: GlobalPoint(x: 1, y: 1)).owner.name == "editor-proc")
        let bare = FakeIdentitySystem(windows: [F.window(pid: editorPID, 0, 0, 10, 10)], signatures: signatures)
        #expect(probe(bare).windowOwner(at: GlobalPoint(x: 1, y: 1)).owner.name == "com.example.Editor")
    }
}

@Suite struct FrontmostAndFocusTests {
    @Test func frontmostAppIsIdentified() {
        let system = FakeIdentitySystem(frontmost: editorPID, signatures: signatures, names: [editorPID: "Editor"])
        let app = probe(system).frontmostApp()
        #expect(app.isCertain)
        #expect(app.pid == editorPID)
        #expect(app.appRef == AppRef(bundleID: "com.example.Editor", teamID: "ABCDE12345", name: "Editor"))
    }

    @Test func noFrontmostAppIsUncertain() {
        #expect(probe(FakeIdentitySystem(frontmost: nil)).frontmostApp().uncertainty == .noFrontmostApp)
    }

    @Test func unsignedFrontmostAppIsUncertain() {
        let system = FakeIdentitySystem(
            frontmost: 5,
            signatures: [5: .found(CodeSignatureFacts(validity: .unsigned, bundleIdentifierAtPath: "x.y"))])
        let app = probe(system).frontmostApp()
        #expect(app.uncertainty == .signatureNotTrusted)
        #expect(app.identity == AppIdentity(bundleID: BundleID("x.y"), signer: .unsigned))
    }

    @Test(arguments: [
        (FocusedApplicationLookup.noFocus, IdentityUncertainty.noFocusedApp),
        (.accessibilityUntrusted, .accessibilityUntrusted),
        (.failed(-25_204), .focusUnreadable(-25_204)),
        (.process(999), .processGone),
    ])
    func unreadableFocusOwnerIsUncertain(lookup: FocusedApplicationLookup, expected: IdentityUncertainty) {
        let owner = probe(FakeIdentitySystem(focus: lookup, signatures: signatures)).focusOwner()
        #expect(owner.uncertainty == expected)
        #expect(owner.identity == .unknown)
    }

    @Test func focusOwnerIsIdentifiedSeparatelyFromFrontmost() {
        let system = FakeIdentitySystem(frontmost: editorPID, focus: .process(viewerPID), signatures: signatures)
        #expect(probe(system).focusOwner().identity.bundleID?.rawValue == "com.apple.Preview")
        #expect(probe(system).frontmostApp().identity.bundleID?.rawValue == "com.example.Editor")
    }

    @Test func focusedWindowTitleIsReadAndCut() {
        let long = String(repeating: "a", count: 600)
        let system = FakeIdentitySystem(frontmost: editorPID, signatures: signatures, focusedTitles: [editorPID: long])
        let probe = probe(system)
        #expect(probe.focusedWindowTitle(of: probe.frontmostApp())?.unicodeScalars.count == 512)
        #expect(probe.focusedWindowTitle(of: .unidentified(.noFrontmostApp)) == nil)
        let untitled = FakeIdentitySystem(frontmost: editorPID, signatures: signatures)
        #expect(IdentityProbe(system: untitled).focusedWindowTitle(of: probe.frontmostApp()) == nil)
    }
}

@Suite struct WindowTitleTests {
    @Test func cutsUnicodeScalarsNotCharacters() {
        // Each "e\u{301}" is one Character but two scalars, so a Character cut would keep twice as much.
        let decomposed = String(repeating: "e\u{301}", count: 300)
        let cut = WindowTitle.cut(decomposed)
        #expect(cut.unicodeScalars.count == 512)
        #expect(cut.count == 256)
        #expect(cut.unicodeScalars.elementsEqual(decomposed.unicodeScalars.prefix(512)))
    }

    @Test(arguments: [0, 1, 511, 512])
    func shortTitlesAreKept(length: Int) {
        let title = String(repeating: "\u{1F600}", count: length)
        #expect(WindowTitle.cut(title) == title)
    }

    @Test func windowHitTitleIsCut() {
        let long = String(repeating: "\u{1F600}", count: 513)
        let hit = owner(at: 1, 1, in: [F.window(pid: editorPID, 0, 0, 10, 10, title: long)])
        #expect(hit.title?.unicodeScalars.count == 512)
        #expect(Measured.maxWindowTitleLength == WindowTitle.maxScalars)
    }
}
