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

    /// Levels that never take a click: the pointer itself and a drag image follow the pointer, so
    /// counting them would attribute every point near the pointer to whoever drew it.
    public static let passThroughLayers: Set<Int> = [
        Int(CGWindowLevelForKey(.cursorWindow)), Int(CGWindowLevelForKey(.draggingWindow)),
    ]

    /// The frontmost window containing `point`. Every level except ``passThroughLayers`` counts,
    /// including the menu bar, status items, the Dock, overlays and the lock screen: a click there acts
    /// on that window's owner, never on a normal window behind it.
    public static func topmost(at point: GlobalPoint, in windows: [IdentityWindowEntry]) -> Outcome {
        for window in windows {
            if let layer = window.layer, passThroughLayers.contains(layer) { continue }
            guard let bounds = window.bounds else { return .unreadable }
            if contains(bounds, point) { return .window(window) }
        }
        return .noWindow
    }

    /// Half-open on the far edges, so adjacent windows never both contain a point.
    static func contains(_ rect: GlobalRect, _ point: GlobalPoint) -> Bool {
        point.x >= rect.x && point.x < rect.x + rect.width && point.y >= rect.y && point.y < rect.y + rect.height
    }
}

/// Measures the apps an effect touches (contract 6.7, 6.8): the frontmost app, the app owning
/// keyboard focus, and the owner of the topmost window under global points. Each call reads the OS
/// afresh; the caller runs it immediately before the event it guards.
public struct IdentityProbe: Sendable {
    public let system: any IdentitySystem

    public init(system: any IdentitySystem) {
        self.system = system
    }

    /// The frontmost app.
    public func frontmostApp() -> MeasuredApp {
        guard let pid = system.frontmostProcess() else { return .unidentified(.noFrontmostApp) }
        return measure(pid: pid, fallbackName: nil)
    }

    /// The app owning keyboard focus. Needs Accessibility; without it the owner is uncertain.
    public func focusOwner() -> MeasuredApp {
        switch system.focusedApplication() {
        case .process(let pid): measure(pid: pid, fallbackName: nil)
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
        var owners: [pid_t: MeasuredApp] = [:]
        return points.map { point in
            switch WindowHitTest.topmost(at: point, in: windows) {
            case .noWindow:
                return WindowOwnerHit(point: point, owner: .unidentified(.noWindow), layer: nil, title: nil)
            case .unreadable:
                return WindowOwnerHit(point: point, owner: .unidentified(.windowUnreadable), layer: nil, title: nil)
            case .window(let window):
                let owner: MeasuredApp
                if let pid = window.ownerPID {
                    if let known = owners[pid] {
                        owner = known
                    } else {
                        owner = measure(pid: pid, fallbackName: window.ownerName)
                        owners[pid] = owner
                    }
                } else {
                    owner = .unidentified(.noOwnerProcess, name: window.ownerName)
                }
                return WindowOwnerHit(
                    point: point, owner: owner, layer: window.layer, title: window.title.map(WindowTitle.cut))
            }
        }
    }

    private func measure(pid: pid_t, fallbackName: String?) -> MeasuredApp {
        let signature = system.codeSignature(of: pid)
        return MeasuredApp(pid: pid, signature: signature, name: system.localizedName(of: pid) ?? fallbackName)
    }
}
