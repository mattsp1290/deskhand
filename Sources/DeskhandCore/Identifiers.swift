/// A string handle restricted to an ASCII alphabet (`defs.json`). Validation walks every byte, so a
/// trailing newline is refused like any other forbidden character, whatever a regex engine's `$` does.
public protocol RestrictedIdentifier: Hashable, Sendable, CustomStringConvertible {
    static var maxLength: Int { get }
    /// The punctuation allowed besides `A-Z a-z 0-9`.
    static var punctuation: String { get }
    var rawValue: String { get }
    init?(_ rawValue: String)
}

extension RestrictedIdentifier {
    public static func isValid(_ rawValue: String) -> Bool {
        let bytes = rawValue.utf8
        return (1...maxLength).contains(bytes.count)
            && bytes.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                    || punctuation.utf8.contains(byte)
            }
    }

    /// What the value must look like, for an `invalid_argument` message.
    public static var requirement: String {
        "1 to \(maxLength) characters from A-Z a-z 0-9 " + punctuation.map(String.init).joined(separator: " ")
    }

    public var description: String { rawValue }
}

/// Names whoever drives the desktop (contract 4.1). A label, not a credential.
public struct HolderID: RestrictedIdentifier {
    public static let maxLength = 128
    public static let punctuation = "._:-"
    public let rawValue: String
    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

/// The caller's idempotency key for one effect call (contract 4.3).
public struct OperationID: RestrictedIdentifier {
    public static let maxLength = 128
    public static let punctuation = "._:-"
    public let rawValue: String
    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

/// A screenshot handle (contract 4.2). deskhand mints `frm_` plus 22 base64url characters.
public struct FrameID: RestrictedIdentifier {
    public static let maxLength = 64
    public static let punctuation = "_-"
    public let rawValue: String
    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

/// A macOS bundle identifier in `permitted_apps`, compared exactly (contract 6.8).
public struct BundleID: RestrictedIdentifier {
    public static let maxLength = 255
    public static let punctuation = "._-"
    public let rawValue: String
    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

/// A `CGDirectDisplayID`. Meaningful only within one ``DisplayConfigGeneration``.
public struct DisplayID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
    public var description: String { String(rawValue) }
}

/// Increases on every display reconfiguration within one run. Callers compare it for equality only.
public struct DisplayConfigGeneration: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { String(rawValue) }
}

/// The five tools, in `tools/list` order.
public enum ToolName: String, CaseIterable, Hashable, Sendable {
    case status, displays, screenshot, pointer, keyboard

    /// Effect tools post input and carry an `operation_id`. A caller treats unknown tools as effects.
    public var isEffect: Bool { self == .pointer || self == .keyboard }
}
