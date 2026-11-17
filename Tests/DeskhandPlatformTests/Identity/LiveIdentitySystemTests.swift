import AppKit
import ApplicationServices
import CoreGraphics
import DeskhandCore
import DeskhandTestSupport
import Foundation
import Security
import Testing

@testable import DeskhandPlatform

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

private func guestCode(of pid: pid_t) -> SecCode? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
    return code
}

private func sleeper() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    return process
}

@Suite struct LiveCodeSignatureTests {
    @Test func launchdIsSignedByApple() throws {
        let lookup = LiveIdentitySystem().codeSignature(of: 1)
        let app = MeasuredApp(pid: 1, signature: lookup, name: nil)
        #expect(app.identity.signer == .apple)
        #expect(app.identity.bundleID?.rawValue == "com.apple.xpc.launchd")
        guard case .found(let facts) = lookup else {
            Issue.record("launchd's signature was not read: \(lookup)")
            return
        }
        #expect(facts.satisfiesAppleAnchor)
        #expect(!facts.satisfiesTeamAnchor)
    }

    /// Apple's own certificate chain is not enough: the leaf must name the team.
    @Test func teamAnchorNeedsAnAppleIssuedCertificateForThatTeam() throws {
        let team = try #require(TeamID("ABCDE12345"))
        #expect(
            LiveIdentitySystem.teamAnchor(team)
                == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
        let launchd = try #require(guestCode(of: 1))
        #expect(LiveIdentitySystem.satisfies(launchd, LiveIdentitySystem.appleAnchor))
        #expect(LiveIdentitySystem.satisfies(launchd, "anchor apple generic"))
        #expect(!LiveIdentitySystem.satisfies(launchd, LiveIdentitySystem.teamAnchor(team)))
        #expect(!LiveIdentitySystem.satisfies(launchd, "not a requirement ("))
    }

    @Test func startTimeNamesOneProcess() throws {
        let system = LiveIdentitySystem()
        let launchd = try #require(system.processStartTime(of: 1))
        #expect(system.processStartTime(of: 1) == launchd)

        let process = try sleeper()
        let pid = process.processIdentifier
        let started = try #require(system.processStartTime(of: pid))
        #expect(system.processStartTime(of: pid) == started)
        #expect(started.seconds >= launchd.seconds)
        #expect(started <= system.wallClock())
        #expect(launchd < started)
        process.terminate()
        process.waitUntilExit()
        #expect(system.processStartTime(of: pid) == nil)
    }

    @Test func exitedProcessIsGone() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(LiveIdentitySystem().codeSignature(of: process.processIdentifier) == .processGone)
        #expect(LiveIdentitySystem().processStartTime(of: process.processIdentifier) == nil)
    }
}

@Suite(.tags(.requiresMacSession), .macSessionTestsEnabled)
struct LiveIdentitySessionTests {
    private let system = LiveIdentitySystem()
    private var probe: IdentityProbe { IdentityProbe(system: system) }

    @Test func frontmostAppIsIdentified() {
        let app = probe.frontmostApp()
        if AXIsProcessTrusted() {
            #expect(app.pid != nil)
            #expect(app.identity.bundleID != nil)
        } else {
            #expect(!app.isCertain)
        }
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

    @Test(arguments: ["com.apple.finder", "com.apple.dock"])
    func systemAppsAreSignedByApple(bundleID: String) throws {
        let running = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first)
        let pid = running.processIdentifier
        let app = MeasuredApp(pid: pid, signature: system.codeSignature(of: pid), name: nil)
        #expect(app.isCertain)
        #expect(app.identity == AppIdentity(bundleID: BundleID(bundleID), signer: .apple))
    }

    @Test func runningTeamSignedAppsMeasureAsTheirTeam() throws {
        let other = try #require(TeamID("ZZZZZZZZZZ"))
        var checked = 0
        for running in NSWorkspace.shared.runningApplications {
            let pid = running.processIdentifier
            guard case .found(let facts) = system.codeSignature(of: pid), facts.validity == .valid, !facts.isAdHoc,
                !facts.satisfiesAppleAnchor, let team = facts.teamIdentifier.flatMap(TeamID.init), team != other,
                let code = guestCode(of: pid)
            else { continue }
            #expect(facts.satisfiesTeamAnchor, "\(running.bundleIdentifier ?? "?") \(team)")
            #expect(MeasuredApp(pid: pid, signature: .found(facts), name: nil).identity.signer == .team(team))
            #expect(!LiveIdentitySystem.satisfies(code, LiveIdentitySystem.teamAnchor(other)))
            checked += 1
        }
        #expect(checked > 0, "no team-signed third-party app is running")
    }

    @Test func pointerLevelWindowsBelongToTheWindowServer() throws {
        let windows = try #require(system.onScreenWindows())
        for window in windows {
            guard let layer = window.layer, WindowHitTest.passThroughLayers.contains(layer) else { continue }
            let pid = try #require(window.ownerPID)
            let owner = MeasuredApp(pid: pid, signature: system.codeSignature(of: pid), name: nil)
            #expect(owner.identity == IdentityProbe.windowServer, "\(window)")
        }
    }
}
