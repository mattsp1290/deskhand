import AppKit
import ApplicationServices
import CoreGraphics
import DeskhandCore
import Foundation
import Security

/// ``IdentitySystem`` backed by the real OS.
///
/// - Windows: `CGWindowListCopyWindowInfo` (on-screen only, desktop elements excluded), front to back.
/// - Frontmost app: `NSWorkspace.frontmostApplication`. Neither CoreGraphics nor Accessibility reports
///   the active app without a grant (the frontmost window's owner is not always the active app), so
///   this one read uses AppKit.
/// - Focus owner: Accessibility's system-wide `kAXFocusedApplicationAttribute`. Needs the grant.
/// - Signer: `SecCodeCopyGuestWithAttributes` by process, validated with `SecCodeCheckValidity` against
///   the code's own designated requirement, then checked against `anchor apple`.
public struct LiveIdentitySystem: IdentitySystem {
    /// How long one Accessibility request to an app may block before it is abandoned.
    public var accessibilityTimeout: Float

    public init(accessibilityTimeout: Float = 0.2) {
        self.accessibilityTimeout = accessibilityTimeout
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
        return .found(
            CodeSignatureFacts(
                validity: validity,
                isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
                satisfiesAppleAnchor: validity == .valid && Self.satisfiesAppleAnchor(code),
                teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
                sealedBundleIdentifier: sealedBundleIdentifier,
                bundleIdentifierAtPath: sealedBundleIdentifier == nil ? Self.bundleIdentifierAtPath(staticCode) : nil))
    }

    public func localizedName(of pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
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

    /// Dynamic code refuses the static-only validation flags; a repeat validation is cheap because the
    /// Security framework caches the first one.
    private static func satisfiesAppleAnchor(_ code: SecCode) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
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
