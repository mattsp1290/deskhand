import CoreGraphics
import DeskhandCore
import Foundation

/// The topmost window under one global point and the app that owns it.
public struct WindowOwnerHit: Hashable, Sendable {
    public let point: GlobalPoint
    /// Uncertain when no window, no owner, or no identity could be found; the policy then refuses.
    public let owner: MeasuredApp
    /// The hit window's level, or `nil` when no window was hit or its level is unreadable.
    public let layer: Int?
    /// The hit window's title cut to ``WindowTitle/maxScalars``, or `nil` when unavailable. The
    /// caller withholds it from `measured` on a denial or for a capture-excluded app.
    public let title: String?
}

/// `window_title` cutting (contract 6.7): Unicode scalars, not `Character`s, so the bound matches the
/// schema's `maxLength` exactly.
public enum WindowTitle {
    public static let maxScalars = Measured.maxWindowTitleLength

    public static func cut(_ title: String) -> String {
        let scalars = title.unicodeScalars
        guard scalars.count > maxScalars else { return title }
        return String(String.UnicodeScalarView(scalars.prefix(maxScalars)))
    }
}

/// Which on-screen window a point lands on.
public enum WindowHitTest {
    public enum Outcome: Hashable, Sendable {
        case window(IdentityWindowEntry)
        case noWindow
        /// A window in front of any hit has no readable frame.
        case unreadable
    }

    /// The levels the pointer and a drag image are drawn at. Both follow the pointer, so counting them
    /// would attribute every point near the pointer to whoever drew it. Any app can put a window at
    /// these levels too, so being there is not enough to be looked through (contract 6.9).
    public static let passThroughLayers: Set<Int> = [
        Int(CGWindowLevelForKey(.cursorWindow)), Int(CGWindowLevelForKey(.draggingWindow)),
    ]

    /// The frontmost window containing `point`. Every level counts, including the menu bar, status
    /// items, the Dock, overlays and the lock screen: a click there acts on that window's owner, never on
    /// a normal window behind it. The one exception is a window at one of ``passThroughLayers`` for
    /// which `isWindowServers` is true; it is asked only about such a window that may cover `point`.
    public static func topmost(
        at point: GlobalPoint, in windows: [IdentityWindowEntry], isWindowServers: (IdentityWindowEntry) -> Bool
    ) -> Outcome {
        for window in windows {
            let covers = window.bounds.map { contains($0, point) }
            if covers == false { continue }
            if let layer = window.layer, passThroughLayers.contains(layer), isWindowServers(window) { continue }
            guard covers == true else { return .unreadable }
            return .window(window)
        }
        return .noWindow
    }

    static func contains(_ rect: GlobalRect, _ point: GlobalPoint) -> Bool {
        point.x >= rect.x && point.x < rect.x + rect.width && point.y >= rect.y && point.y < rect.y + rect.height
    }
}

/// Measures the apps an effect touches (contract 6.7, 6.8): the frontmost app, the app owning
/// keyboard focus, and the owner of the topmost window under global points. Each call reads the OS
/// afresh; the caller runs it immediately before the event it guards.
///
/// A process is identified only if it is the same process from when its pid was obtained until its
/// code and name have been read: a pid reused in between measures as ``IdentityUncertainty/processGone``.
public struct IdentityProbe: Sendable {
    /// The window server, the only owner whose pointer and drag-image windows are looked through.
    public static let windowServer = AppIdentity(bundleID: BundleID("com.apple.WindowServer"), signer: .apple)

    public let system: any IdentitySystem

    public init(system: any IdentitySystem) {
        self.system = system
    }

    /// The frontmost app. AppKit's reading is confirmed against Accessibility's focused application
    /// after the app is measured; when they differ (a stale reading, or a non-activating panel of
    /// another app holding focus) or focus cannot be read, the frontmost app is uncertain.
    public func frontmostApp() -> MeasuredApp {
        guard let pid = system.frontmostProcess() else { return .unidentified(.noFrontmostApp) }
        let app = measure(pid: pid, started: system.processStartTime(of: pid), fallbackName: nil)
        guard app.isCertain else { return app }
        guard system.focusedApplication() == .process(pid) else { return .unidentified(.frontmostUnconfirmed) }
        return app
    }

    /// The app owning keyboard focus. Needs Accessibility; without it the owner is uncertain.
    public func focusOwner() -> MeasuredApp {
        switch system.focusedApplication() {
        case .process(let pid): measure(pid: pid, started: system.processStartTime(of: pid), fallbackName: nil)
        case .noFocus: .unidentified(.noFocusedApp)
        case .accessibilityUntrusted: .unidentified(.accessibilityUntrusted)
        case .failed(let error): .unidentified(.focusUnreadable(error))
        }
    }

    /// `keyboard`'s `window_title`: the title of `app`'s focused window, cut, or `nil`.
    public func focusedWindowTitle(of app: MeasuredApp) -> String? {
        guard let pid = app.pid else { return nil }
        return system.focusedWindowTitle(of: pid).map(WindowTitle.cut)
    }

    /// The owner of the topmost window under `point`.
    public func windowOwner(at point: GlobalPoint) -> WindowOwnerHit {
        windowOwners(at: [point])[0]
    }

    /// The owner of the topmost window under each point, in order, from one window list. Each process is
    /// identified once, so a sampled drag path costs one signature check per distinct owner.
    public func windowOwners(at points: [GlobalPoint]) -> [WindowOwnerHit] {
        guard !points.isEmpty else { return [] }
        guard let windows = system.onScreenWindows() else {
            return points.map {
                WindowOwnerHit(point: $0, owner: .unidentified(.windowListUnavailable), layer: nil, title: nil)
            }
        }
        // Read with the list, so an owner whose pid is reused before it is measured measures as gone.
        var started: [pid_t: ProcessStartTime] = [:]
        for pid in Set(windows.compactMap(\.ownerPID)) { started[pid] = system.processStartTime(of: pid) }
        var owners: [pid_t: MeasuredApp] = [:]
        func owner(of pid: pid_t, fallbackName: String?) -> MeasuredApp {
            if let known = owners[pid] { return known }
            let app = measure(pid: pid, started: started[pid], fallbackName: fallbackName)
            owners[pid] = app
            return app
        }
        func isWindowServers(_ window: IdentityWindowEntry) -> Bool {
            guard let pid = window.ownerPID else { return false }
            let app = owner(of: pid, fallbackName: window.ownerName)
            return app.isCertain && app.identity == Self.windowServer
        }
        return points.map { point in
            switch WindowHitTest.topmost(at: point, in: windows, isWindowServers: isWindowServers) {
            case .noWindow:
                return WindowOwnerHit(point: point, owner: .unidentified(.noWindow), layer: nil, title: nil)
            case .unreadable:
                return WindowOwnerHit(point: point, owner: .unidentified(.windowUnreadable), layer: nil, title: nil)
            case .window(let window):
                let hitOwner =
                    window.ownerPID.map { owner(of: $0, fallbackName: window.ownerName) }
                    ?? .unidentified(.noOwnerProcess, name: window.ownerName)
                return WindowOwnerHit(
                    point: point, owner: hitOwner, layer: window.layer, title: window.title.map(WindowTitle.cut))
            }
        }
    }

    private func measure(pid: pid_t, started: ProcessStartTime?, fallbackName: String?) -> MeasuredApp {
        let gone = MeasuredApp(pid: pid, signature: .processGone, name: fallbackName)
        guard let started else { return gone }
        let signature = system.codeSignature(of: pid)
        let name = system.localizedName(of: pid)
        guard system.processStartTime(of: pid) == started else { return gone }
        return MeasuredApp(pid: pid, signature: signature, name: name ?? fallbackName)
    }
}
