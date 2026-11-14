import ApplicationServices
import CoreGraphics
import DeskhandCore
import DeskhandPlatform
import DeskhandTestSupport
import Foundation
import Testing

@Suite struct WindowInfoParsingTests {
    @Test func readsAWindowServerEntry() {
        let info: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 77), kCGWindowOwnerPID as String: NSNumber(value: 1099),
            kCGWindowOwnerName as String: "iTerm2", kCGWindowLayer as String: NSNumber(value: 24),
            kCGWindowBounds as String: CGRect(x: -1512, y: -33, width: 1512.5, height: 859).dictionaryRepresentation,
            kCGWindowName as String: "shell",
        ]
        let entry = IdentityWindowEntry(windowInfo: info)
        #expect(
            entry
                == IdentityWindowEntry(
                    windowNumber: 77, ownerPID: 1099, ownerName: "iTerm2", layer: 24,
                    bounds: GlobalRect(x: -1512, y: -33, width: 1512.5, height: 859), title: "shell"))
    }

    @Test func leavesUnreadableMembersNil() {
        let entry = IdentityWindowEntry(windowInfo: [
            kCGWindowOwnerPID as String: "not a number", kCGWindowBounds as String: "nope",
        ])
        #expect(entry == IdentityWindowEntry(ownerPID: nil, layer: nil, bounds: nil))
    }
}

/// Reads real code signatures. No grant or GUI session is needed to inspect a running process's code.
@Suite struct LiveCodeSignatureTests {
    @Test func launchdIsSignedByApple() {
        let app = MeasuredApp(pid: 1, signature: LiveIdentitySystem().codeSignature(of: 1), name: nil)
        #expect(app.identity.signer == .apple)
        #expect(app.identity.bundleID?.rawValue == "com.apple.xpc.launchd")
    }

    @Test func exitedProcessIsGone() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(LiveIdentitySystem().codeSignature(of: process.processIdentifier) == .processGone)
    }
}

@Suite(.tags(.requiresMacSession), .macSessionTestsEnabled)
struct LiveIdentitySessionTests {
    private let probe = IdentityProbe(system: LiveIdentitySystem())

    @Test func frontmostAppIsIdentified() {
        let app = probe.frontmostApp()
        #expect(app.pid != nil)
        #expect(app.identity.bundleID != nil)
    }

    /// Needs the menu bar visible: no full-screen app on the main display.
    @Test func menuBarIsOwnedAboveTheNormalLevel() {
        let main = CGDisplayBounds(CGMainDisplayID())
        let hit = probe.windowOwner(at: GlobalPoint(x: main.midX, y: main.minY + 2))
        #expect(hit.layer != nil)
        #expect(hit.owner.pid != nil)
        #expect(hit.layer.map { $0 > 0 } == true)
    }

    @Test func focusOwnerIsReadOnlyWithAccessibility() {
        let focus = probe.focusOwner()
        if AXIsProcessTrusted() {
            #expect(focus.pid != nil)
        } else {
            #expect(focus.uncertainty == .accessibilityUntrusted)
        }
    }
}
