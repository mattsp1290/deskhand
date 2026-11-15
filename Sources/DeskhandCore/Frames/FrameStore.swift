public enum FrameRecordError: Error, Hashable, Sendable {
    /// Every frame was invalidated while this one was being captured, so it is discarded and no frame
    /// is minted (contract 10.3: leaving `ok` stops a screenshot in flight).
    case invalidatedDuringCapture
    /// The capture's parts disagree (pixels not of the output size, a scale or age out of range).
    case inconsistentCapture
}

/// The outcome of ``FrameStore/validate(_:in:for:displayConfigGeneration:now:)``.
public enum FrameValidation: Sendable {
    case valid(LiveFrame)
    /// Refused with `stale_frame` and this reason.
    case stale(StaleFrameReason)
}

/// The frames deskhand currently knows (contract 4.2, 8.3).
///
/// A value type: exactly one owner holds it (the server's request-serializing actor) and every
/// mutation goes through that owner. Only the latest frame per (principal, `holder_id`,
/// `display_id`) keeps its pixels; a superseded frame keeps its record so that it can still be refused
/// as `not_latest`. Both sets are bounded, and a frame dropped from them is refused as `unknown`, which
/// the contract allows for any discarded frame.
///
/// Live frames are bounded per scope first: a scope over ``defaultMaxLiveFramesPerScope`` loses its
/// own oldest. The bound over all scopes then takes the oldest frame of a scope that is neither the
/// recording one nor the lease holder's, so screenshots under one `holder_id` never discard the
/// frames the lease holder acts on (contract 4.2: only the lease holder's frames matter for an
/// effect). Only when every other live frame is the lease holder's does a scope give up its own.
/// The residual case: past the global bound, one non-holding scope's screenshots can discard another
/// non-holding scope's frame, which that scope could not act on without taking a new one anyway.
public struct FrameStore: Sendable {
    /// Changes on every ``invalidateAll()``. A capture started under one epoch cannot be recorded in another.
    public struct Epoch: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    /// The contract sets no bound; each live frame holds up to `MAX_PIXELS * 3` bytes of pixels.
    public static let defaultMaxLiveFrames = 16
    /// One latest frame per display; more displays than this on one Mac is not expected.
    public static let defaultMaxLiveFramesPerScope = 4
    public static let defaultMaxSupersededFrames = 1024

    private struct LatestKey: Hashable {
        let scope: FrameScope
        let displayID: DisplayID
    }

    public private(set) var epoch = Epoch(value: 0)
    private var live: [FrameID: LiveFrame] = [:]
    private var latest: [LatestKey: FrameID] = [:]
    private var superseded: [FrameID: Frame] = [:]
    private let maxLiveFrames: Int
    private let maxLiveFramesPerScope: Int
    private let maxSupersededFrames: Int

    public init(
        maxLiveFrames: Int = Self.defaultMaxLiveFrames, maxLiveFramesPerScope: Int = Self.defaultMaxLiveFramesPerScope,
        maxSupersededFrames: Int = Self.defaultMaxSupersededFrames
    ) {
        self.maxLiveFrames = max(1, maxLiveFrames)
        self.maxLiveFramesPerScope = max(1, maxLiveFramesPerScope)
        self.maxSupersededFrames = max(0, maxSupersededFrames)
    }

    public var liveFrameCount: Int { live.count }
    public var supersededFrameCount: Int { superseded.count }

    /// Mints a frame for `capture`, makes it the latest for its scope and display, and supersedes the
    /// previous latest. Frames older than their own `max_age_ms` at `now` are dropped on the way.
    /// - Parameters:
    ///   - leaseHolder: the scope of the current lease holder, if any: its frames are kept while any
    ///     other scope's frame can be dropped instead.
    ///   - epoch: ``epoch`` as read before the capture started.
    public mutating func record(
        _ capture: FrameCapture, for scope: FrameScope, leaseHolder: FrameScope?, startedIn epoch: Epoch,
        now: Timestamp, using generator: inout some RandomNumberGenerator
    ) throws(FrameRecordError) -> Frame {
        guard epoch == self.epoch else { throw .invalidatedDuringCapture }
        guard capture.isConsistent else { throw .inconsistentCapture }
        dropExpired(at: now)

        var id = FrameID.mint(using: &generator)
        while live[id] != nil || superseded[id] != nil { id = FrameID.mint(using: &generator) }
        let frame = Frame(id: id, scope: scope, capture: capture)
        let key = LatestKey(scope: scope, displayID: capture.displayID)
        if let previous = latest[key], let previousFrame = live.removeValue(forKey: previous) {
            superseded[previous] = previousFrame.frame
        }
        live[id] = LiveFrame(frame: frame, pixels: capture.pixels)
        latest[key] = id

        let own = { (frame: Frame) in frame.scope == scope && frame.id != id }
        while live.values.lazy.map(\.frame).filter(own).count >= maxLiveFramesPerScope,
            let oldest = oldestID(in: live.values.lazy.map(\.frame).filter(own), except: id)
        {
            dropLive(oldest)
        }
        while live.count > maxLiveFrames {
            let frames = live.values.lazy.map(\.frame)
            let others = frames.filter { $0.scope != scope && $0.scope != leaseHolder }
            guard let oldest = oldestID(in: others, except: id) ?? oldestID(in: frames.filter(own), except: id) else {
                break
            }
            dropLive(oldest)
        }
        while superseded.count > maxSupersededFrames, let oldest = oldestID(in: superseded.values, except: nil) {
            superseded[oldest] = nil
        }
        return frame
    }

    /// ``record(_:for:leaseHolder:startedIn:now:using:)`` with the system's secure generator.
    public mutating func record(
        _ capture: FrameCapture, for scope: FrameScope, leaseHolder: FrameScope?, startedIn epoch: Epoch,
        now: Timestamp
    ) throws(FrameRecordError) -> Frame {
        var generator = SystemRandomNumberGenerator()
        return try record(capture, for: scope, leaseHolder: leaseHolder, startedIn: epoch, now: now, using: &generator)
    }

    /// The frame named `id` if `scope` owns it, live or superseded. Under another scope it does not exist.
    public func lookup(_ id: FrameID, in scope: FrameScope) -> Frame? {
        let frame = live[id]?.frame ?? superseded[id]
        return frame?.scope == scope ? frame : nil
    }

    /// The latest frame `scope` took of `displayID`.
    public func latest(in scope: FrameScope, displayID: DisplayID) -> LiveFrame? {
        latest[LatestKey(scope: scope, displayID: displayID)].flatMap { live[$0] }
    }

    /// Checks every staleness rule except `pixels_changed` (contract 8.3, refusal step 9), in the
    /// contract's order, and returns the frame or the first reason that applies.
    public func validate(
        _ id: FrameID, in scope: FrameScope, for use: FrameUse, displayConfigGeneration: DisplayConfigGeneration,
        now: Timestamp
    ) -> FrameValidation {
        guard let frame = lookup(id, in: scope) else { return .stale(.unknown) }
        let candidate = Candidate(
            frame: frame, isLatest: live[id] != nil, use: use, displayConfigGeneration: displayConfigGeneration,
            now: now)
        if let failed = Self.staleness.first(where: { $0.holds(candidate) }) { return .stale(failed.reason) }
        guard let liveFrame = live[id] else { return .stale(.notLatest) }
        return .valid(liveFrame)
    }

    /// Forgets every frame of every holder (leaving `ok`, a restart) and starts a new epoch, so a capture
    /// already in flight cannot be recorded either.
    public mutating func invalidateAll() {
        live = [:]
        latest = [:]
        superseded = [:]
        epoch = Epoch(value: epoch.value &+ 1)
    }

    private struct Candidate {
        let frame: Frame
        let isLatest: Bool
        let use: FrameUse
        let displayConfigGeneration: DisplayConfigGeneration
        let now: Timestamp
    }

    private static let staleness: [(reason: StaleFrameReason, holds: @Sendable (Candidate) -> Bool)] = [
        (.displayChanged, { $0.frame.displayConfigGeneration != $0.displayConfigGeneration }),
        (.notLatest, { !$0.isLatest }),
        (.tooOld, { $0.frame.isTooOld(at: $0.now) }),
        (
            .frontmostChanged,
            {
                guard case .keyboard(let frontmost) = $0.use else { return false }
                return frontmost != $0.frame.frontmostApp
            }
        ),
    ]

    private mutating func dropExpired(at now: Timestamp) {
        for (id, entry) in live where entry.frame.isTooOld(at: now) && !entry.frame.isCapturedAfter(now) {
            dropLive(id)
        }
        for (id, frame) in superseded where frame.isTooOld(at: now) && !frame.isCapturedAfter(now) {
            superseded[id] = nil
        }
    }

    private mutating func dropLive(_ id: FrameID) {
        guard let frame = live.removeValue(forKey: id)?.frame else { return }
        let key = LatestKey(scope: frame.scope, displayID: frame.displayID)
        if latest[key] == id { latest[key] = nil }
    }

    private func oldestID(in frames: some Sequence<Frame>, except kept: FrameID?) -> FrameID? {
        frames.filter { $0.id != kept }
            .min { ($0.capturedAt, $0.id.rawValue) < ($1.capturedAt, $1.id.rawValue) }?.id
    }
}

extension Frame {
    fileprivate func isCapturedAfter(_ now: Timestamp) -> Bool { capturedAt > now }
}
