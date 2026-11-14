/// A modifier key. Declaration order is press order; release runs in reverse (contract 6.6).
public enum Modifier: String, CaseIterable, Comparable, Sendable {
    case control, option, shift, command

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum MouseButton: String, CaseIterable, Sendable {
    case left, right, middle
}

/// The arguments every effect call shares, around a tool-specific `action`.
public struct EffectArguments<Action: Hashable & Sendable>: Hashable, Sendable {
    public let holderID: HolderID
    public let frameID: FrameID
    public let operationID: OperationID
    /// The caller's narrowing of the app policy (contract 6.8). `nil` when absent; never empty.
    public let permittedApps: Set<BundleID>?
    public let action: Action

    init(arguments: JSONObject, action decodeAction: ValueDecoder<Action>) throws(ArgumentError) {
        let names: Set = ["holder_id", "frame_id", "operation_id", "permitted_apps", "action"]
        let reader = try ObjectReader(.object(arguments), at: .root, allowing: names)
        holderID = try reader.required("holder_id", Decode.identifier(HolderID.self))
        frameID = try reader.required("frame_id", Decode.identifier(FrameID.self))
        operationID = try reader.required("operation_id", Decode.identifier(OperationID.self))
        permittedApps = try reader.optional("permitted_apps", Decode.permittedApps)
        action = try reader.required("action", decodeAction)
    }
}

/// `holder_id` and `operation_id` read on their own, so that a refusal before or during argument
/// validation can echo `operation_id` and look up an existing record (contract 9.5, steps 1 to 3).
public struct EffectHandles: Hashable, Sendable {
    public let holderID: HolderID?
    public let operationID: OperationID?

    public init(arguments: JSONObject) {
        holderID = arguments["holder_id"]?.stringValue.flatMap(HolderID.init)
        operationID = arguments["operation_id"]?.stringValue.flatMap(OperationID.init)
    }
}

/// An application as deskhand measured it (`defs.json#/$defs/app_ref`).
public struct AppRef: Hashable, Sendable, JSONRepresentable {
    public var bundleID: String?
    public var teamID: String?
    public var name: String

    public init(bundleID: String?, teamID: String?, name: String) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
    }

    public var jsonValue: JSONValue {
        [
            "bundle_id": bundleID.map(JSONValue.string) ?? .null, "team_id": teamID.map(JSONValue.string) ?? .null,
            "name": .string(name),
        ]
    }
}

/// Facts taken at the app-policy check before an effect's first event (contract 6.7).
public struct Measured: Hashable, Sendable, JSONRepresentable {
    public static let maxWindowTitleLength = 512

    public let frontmostApp: AppRef
    /// `pointer`: the app owning the topmost window under the first target. `keyboard`: `nil`.
    public let targetApp: AppRef?
    /// At most 512 code points; longer titles are cut.
    public let windowTitle: String?
    /// `pointer`: where the first target mapped. `keyboard`: `nil`.
    public let globalPoint: GlobalPoint?
    public let measuredAt: Timestamp

    public init(
        frontmostApp: AppRef, targetApp: AppRef?, windowTitle: String?, globalPoint: GlobalPoint?,
        measuredAt: Timestamp
    ) {
        self.frontmostApp = frontmostApp
        self.targetApp = targetApp
        self.windowTitle = windowTitle.map {
            String(String.UnicodeScalarView($0.unicodeScalars.prefix(Self.maxWindowTitleLength)))
        }
        self.globalPoint = globalPoint
        self.measuredAt = measuredAt
    }

    public var jsonValue: JSONValue {
        [
            "frontmost_app": frontmostApp.jsonValue, "target_app": targetApp?.jsonValue ?? .null,
            "window_title": windowTitle.map(JSONValue.string) ?? .null,
            "global_point": globalPoint?.jsonValue ?? .null, "measured_at": measuredAt.jsonValue,
        ]
    }
}

/// The lifecycle of an operation record (contract 4.3).
public enum OperationStatus: String, CaseIterable, Sendable {
    case accepted, executing, completed, aborted, failed
    case failedBeforeExecution = "failed_before_execution"
    case abortedByRestart = "aborted_by_restart"

    public var isTerminal: Bool { self != .accepted && self != .executing }
}

/// `operation` in a tool error: the record as it stood when the response was produced.
public struct OperationView: Hashable, Sendable, JSONRepresentable {
    public var status: OperationStatus
    public var eventsPosted: Int

    public init(status: OperationStatus, eventsPosted: Int) {
        self.status = status
        self.eventsPosted = eventsPosted
    }

    public var jsonValue: JSONValue { ["status": .string(status.rawValue), "events_posted": JSONValue(eventsPosted)] }
}

/// `structuredContent` of a successful `pointer` or `keyboard` call (`defs.json#/$defs/effect_result`).
public struct EffectResult: Hashable, Sendable, JSONRepresentable {
    public var operationID: OperationID
    public var frameID: FrameID
    public var eventsPosted: Int
    /// `true` when this is the stored result returned to a repeat; that call posted nothing.
    public var replayed: Bool
    public var measured: Measured
    public var completedAt: Timestamp

    public init(
        operationID: OperationID, frameID: FrameID, eventsPosted: Int, replayed: Bool, measured: Measured,
        completedAt: Timestamp
    ) {
        self.operationID = operationID
        self.frameID = frameID
        self.eventsPosted = eventsPosted
        self.replayed = replayed
        self.measured = measured
        self.completedAt = completedAt
    }

    public var jsonValue: JSONValue {
        [
            "operation_id": .string(operationID.rawValue), "status": .string(OperationStatus.completed.rawValue),
            "events_posted": JSONValue(eventsPosted), "replayed": .bool(replayed),
            "frame_id": .string(frameID.rawValue), "measured": measured.jsonValue,
            "completed_at": completedAt.jsonValue,
        ]
    }
}
