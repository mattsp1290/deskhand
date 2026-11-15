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
    public let frameID: FrameID?
    public let operationID: OperationID?

    public init(arguments: JSONObject) {
        holderID = arguments["holder_id"]?.stringValue.flatMap(HolderID.init)
        frameID = arguments["frame_id"]?.stringValue.flatMap(FrameID.init)
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

    /// The app as the policy identified it, with the name the platform reported. The one way from
    /// a measured ``AppIdentity`` to what goes on the wire.
    public init(_ identity: AppIdentity, name: String) {
        self.init(bundleID: identity.bundleID?.rawValue, teamID: identity.signer.teamIdentifier, name: name)
    }

    /// An app deskhand could not determine at all (contract 6.3, 6.9).
    public static let undetermined = AppRef(bundleID: nil, teamID: nil, name: "")

    public var jsonValue: JSONValue {
        [
            "bundle_id": bundleID.map(JSONValue.string) ?? .null, "team_id": teamID.map(JSONValue.string) ?? .null,
            "name": .string(name),
        ]
    }
}

/// `measured.drag_end`: the facts of a drag's last point, taken at the same check as the first.
public struct DragEnd: Hashable, Sendable, JSONRepresentable {
    public let targetApp: AppRef
    /// Only ever a ``WindowTitle``: one the app policy shows.
    public let windowTitle: String?
    public let globalPoint: GlobalPoint

    public init(targetApp: AppRef, windowTitle: WindowTitle?, globalPoint: GlobalPoint) {
        self.targetApp = targetApp
        self.windowTitle = windowTitle?.text
        self.globalPoint = globalPoint
    }

    public var jsonValue: JSONValue {
        [
            "target_app": targetApp.jsonValue, "window_title": windowTitle.map(JSONValue.string) ?? .null,
            "global_point": globalPoint.jsonValue,
        ]
    }
}

/// Facts taken at an app-policy check (contract 6.7). On a success, and on every error of an
/// admitted call but `denied_app`, they come from the last look, the check immediately before the
/// first event. `log_unavailable` reports the check before admission, and `denied_app` the check
/// that failed.
public struct Measured: Hashable, Sendable, JSONRepresentable {
    public static let maxWindowTitleLength = 512

    public let frontmostApp: AppRef
    /// `pointer`: the app owning the topmost window under the first target. `keyboard`: the app that
    /// owns keyboard focus. `nil` only on an error whose check failed before it was measured.
    public let targetApp: AppRef?
    /// Only ever a ``WindowTitle``: one the app policy shows, at most 512 Unicode scalar values.
    public let windowTitle: String?
    /// `pointer`: where the first target mapped. `keyboard`: `nil`.
    public let globalPoint: GlobalPoint?
    /// `pointer` `drag` only.
    public let dragEnd: DragEnd?
    public let measuredAt: Timestamp

    public init(
        frontmostApp: AppRef, targetApp: AppRef?, windowTitle: WindowTitle?, globalPoint: GlobalPoint?,
        dragEnd: DragEnd? = nil, measuredAt: Timestamp
    ) {
        self.frontmostApp = frontmostApp
        self.targetApp = targetApp
        self.windowTitle = windowTitle?.text
        self.globalPoint = globalPoint
        self.dragEnd = dragEnd
        self.measuredAt = measuredAt
    }

    /// What `denied_app` reports (contract 6.7, 9.2): no window title, and no `drag_end`, because
    /// the facts then describe only the check that failed.
    public var forDeniedApp: Measured {
        Measured(
            frontmostApp: frontmostApp, targetApp: targetApp, windowTitle: nil, globalPoint: globalPoint,
            measuredAt: measuredAt)
    }

    fileprivate var identifiesEveryApp: Bool {
        frontmostApp.bundleID != nil && targetApp?.bundleID != nil
            && (dragEnd.map { $0.targetApp.bundleID != nil } ?? true)
    }

    public var jsonValue: JSONValue {
        var object: JSONObject = [
            "frontmost_app": frontmostApp.jsonValue, "target_app": targetApp?.jsonValue ?? .null,
            "window_title": windowTitle.map(JSONValue.string) ?? .null,
            "global_point": globalPoint?.jsonValue ?? .null, "measured_at": measuredAt.jsonValue,
        ]
        object["drag_end"] = dragEnd?.jsonValue
        return .object(object)
    }
}

/// `measured` of a success (contract 6.7), checked once when it is built: the frontmost app, the
/// target app and, for a drag, the app at its last point all carry a `bundle_id`; a `pointer`
/// success has the global point of its first target, and `drag_end` exactly for a `drag`; a
/// `keyboard` success has neither. The app policy refuses a call for which these could not be
/// measured, so the last look of a call that completes has them, and an ``EffectResult`` cannot be
/// built without them.
public struct SuccessMeasured: Hashable, Sendable {
    public let measured: Measured

    /// `nil` unless `measured` has the shape of a `pointer` success for `action`.
    public init?(pointer measured: Measured, action: PointerAction) {
        let isDrag: Bool
        if case .drag = action { isDrag = true } else { isDrag = false }
        guard measured.identifiesEveryApp, measured.globalPoint != nil, (measured.dragEnd != nil) == isDrag else {
            return nil
        }
        self.measured = measured
    }

    /// `nil` unless `measured` has the shape of a `keyboard` success.
    public init?(keyboard measured: Measured) {
        guard measured.identifiesEveryApp, measured.globalPoint == nil, measured.dragEnd == nil else { return nil }
        self.measured = measured
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
    /// Taken at the last look, and always of a shape ``SuccessMeasured`` accepts.
    public let measured: Measured
    public var completedAt: Timestamp

    public init(
        operationID: OperationID, frameID: FrameID, eventsPosted: Int, replayed: Bool, measured: SuccessMeasured,
        completedAt: Timestamp
    ) {
        self.operationID = operationID
        self.frameID = frameID
        self.eventsPosted = eventsPosted
        self.replayed = replayed
        self.measured = measured.measured
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
