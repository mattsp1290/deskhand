import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import DeskhandCore
import Foundation
import Security

/// ``IdentitySystem`` backed by the real OS.
///
/// - Windows: `CGWindowListCopyWindowInfo` (on-screen only, desktop elements excluded), front to back.
/// - Frontmost app: `NSWorkspace.frontmostApplication`. Neither CoreGraphics nor Accessibility reports
///   the active app without a grant (the frontmost window's owner is not always the active app), so
///   this one read uses AppKit, and is only as fresh as the main run loop.
/// - Activation: the app's own `kAXFrontmostAttribute`. Needs the grant.
/// - Focus owner: Accessibility's system-wide `kAXFocusedApplicationAttribute`. Needs the grant.
/// - Signer: `SecCodeCopyGuestWithAttributes` by process, validated with `SecCodeCheckValidity` against
///   the code's own designated requirement, then against `anchor apple`, then against an Apple-issued
///   certificate for its team. The signer writes both the team identifier and the designated
///   requirement, so only the last check ties the team to Apple's certificate authority.
/// - Start time: `sysctl` `KERN_PROC_PID`, which answers for other users' processes where
///   `proc_pidinfo` is refused.
/// - Wall clock: `gettimeofday`, the clock the kernel records `p_starttime` on.
public struct LiveIdentitySystem: IdentitySystem {
    /// How long one Accessibility request to an app may block before it is abandoned.
    public var accessibilityTimeout: Float

    public init(accessibilityTimeout: Float = 0.2) {
        self.accessibilityTimeout = accessibilityTimeout
    }

    public func wallClock() -> ProcessStartTime {
        var now = timeval()
        gettimeofday(&now, nil)
        return ProcessStartTime(seconds: Int64(now.tv_sec), microseconds: Int32(now.tv_usec))
    }

    public func onScreenWindows() -> [IdentityWindowEntry]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return list.map(IdentityWindowEntry.init(windowInfo:))
    }

    public func frontmostProcess() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func activation(of pid: pid_t) -> ActivationLookup {
        guard AXIsProcessTrusted() else { return .accessibilityUntrusted }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, accessibilityTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &value)
        switch error {
        case .success: break
        case .apiDisabled: return .accessibilityUntrusted
        default: return .failed(error.rawValue)
        }
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return .failed(AXError.failure.rawValue) }
        return CFBooleanGetValue((value as! CFBoolean)) ? .active : .inactive
    }

    public func focusedApplication() -> FocusedApplicationLookup {
        guard AXIsProcessTrusted() else { return .accessibilityUntrusted }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value)
        switch error {
        case .success: break
        case .noValue: return .noFocus
        case .apiDisabled: return .accessibilityUntrusted
        default: return .failed(error.rawValue)
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failed(AXError.failure.rawValue) }
        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(value as! AXUIElement, &pid)
        return pidError == .success ? .process(pid) : .failed(pidError.rawValue)
    }

    public func codeSignature(of pid: pid_t) -> CodeSignatureLookup {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
        guard status == errSecSuccess, let code = guest else { return Self.lookupFailure(status) }

        var staticGuest: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticGuest)
        guard status == errSecSuccess, let staticCode = staticGuest else { return Self.lookupFailure(status) }

        var rawInfo: CFDictionary?
        status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo)
        guard status == errSecSuccess, let info = rawInfo as? [String: Any] else { return Self.lookupFailure(status) }

        let validity: CodeSignatureFacts.Validity
        switch Self.checkAgainstDesignatedRequirement(code, staticCode) {
        case errSecSuccess: validity = .valid
        case errSecCSUnsigned: validity = .unsigned
        case let status where Self.meansProcessGone(status): return .processGone
        default: validity = .invalid
        }

        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let plist = info[kSecCodeInfoPList as String] as? [String: Any]
        let sealedBundleIdentifier = plist?[kCFBundleIdentifierKey as String] as? String
        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        let team = validity == .valid ? teamIdentifier.flatMap(TeamID.init) : nil
        return .found(
            CodeSignatureFacts(
                validity: validity,
                isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
                satisfiesAppleAnchor: validity == .valid && Self.satisfies(code, Self.appleAnchor),
                teamIdentifier: teamIdentifier,
                satisfiesTeamAnchor: team.map { Self.satisfies(code, Self.teamAnchor($0)) } ?? false,
                sealedBundleIdentifier: sealedBundleIdentifier,
                bundleIdentifierAtPath: sealedBundleIdentifier == nil ? Self.bundleIdentifierAtPath(staticCode) : nil))
    }

    public func localizedName(of pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    public func processStartTime(of pid: pid_t) -> ProcessStartTime? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid,
            info.kp_proc.p_stat != SZOMB
        else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return ProcessStartTime(seconds: Int64(started.tv_sec), microseconds: Int32(started.tv_usec))
    }

    public func focusedWindowTitle(of pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, accessibilityTimeout)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    private static func lookupFailure(_ status: OSStatus) -> CodeSignatureLookup {
        meansProcessGone(status) ? .processGone : .unreadable(status)
    }

    /// A process that has exited is reported as `ESRCH` in the POSIX range, not only as no such code.
    private static func meansProcessGone(_ status: OSStatus) -> Bool {
        status == errSecCSNoSuchCode || status == OSStatus(kPOSIXErrorESRCH)
    }

    private static func checkAgainstDesignatedRequirement(_ code: SecCode, _ staticCode: SecStaticCode) -> OSStatus {
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else { return status }
        return SecCodeCheckValidity(code, [], requirement)
    }

    static let appleAnchor = "anchor apple"

    /// `anchor apple generic` admits only certificates Apple issues to developers (Developer ID, Mac App
    /// Store, development); the leaf's organizational unit is the team Apple issued it to. A team is
    /// `A-Z 0-9` only, so it cannot break out of the quoted string.
    static func teamAnchor(_ team: TeamID) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team.rawValue)\""
    }

    static func satisfies(_ code: SecCode, _ requirementText: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func bundleIdentifierAtPath(_ staticCode: SecStaticCode) -> String? {
        var path: CFURL?
        guard SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path,
            let bundle = CFBundleCreate(kCFAllocatorDefault, path)
        else { return nil }
        return CFBundleGetIdentifier(bundle) as String?
    }
}

extension IdentityWindowEntry {
    /// Reads one `CGWindowListCopyWindowInfo` entry. Any member of the wrong type is left `nil`.
    public init(windowInfo info: [String: Any]) {
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap {
            CGRect(dictionaryRepresentation: $0 as CFDictionary)
        }
        self.init(
            windowNumber: (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            ownerPID: (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            ownerName: info[kCGWindowOwnerName as String] as? String,
            layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
            bounds: bounds.map {
                GlobalRect(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height)
            },
            title: info[kCGWindowName as String] as? String)
    }
}
