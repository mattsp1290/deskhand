/// The allowance file after the file and contents checks, before the clock is consulted. This is
/// what may be cached: the contents, not the verdict (contract 14.4).
public enum AllowanceSnapshot: Hashable, Sendable {
    case missing
    case invalid(AllowanceInvalidReason)
    /// Passed every check of contract 14.1 and 14.2, and `mac` names this Mac.
    case allowance(Allowance)
}

/// Reads and judges this Mac's allowance file (contract 14).
public struct AllowanceReader: Sendable {
    /// A valid allowance is about 120 bytes; a larger file is refused without being parsed.
    public static let maxFileBytes = 4096

    public let path: String
    /// This Mac's configured name, which the allowance's `mac` must equal.
    public let mac: String
    /// `ALLOWANCE_SKEW_TOLERANCE_MS`, applied to `not_before` only.
    public let skewToleranceMs: Int
    private let probe: any AllowanceFileProbe

    public init(
        path: String, mac: String, skewToleranceMs: Int, probe: any AllowanceFileProbe = POSIXAllowanceFileProbe()
    ) {
        self.path = path
        self.mac = mac
        self.skewToleranceMs = skewToleranceMs
        self.probe = probe
    }

    public init(config: DeskhandConfig, probe: any AllowanceFileProbe = POSIXAllowanceFileProbe()) {
        self.init(
            path: config.allowance.path, mac: config.mac, skewToleranceMs: config.allowance.skewToleranceMs,
            probe: probe)
    }

    /// Reads the file and runs every check except the clock.
    public func read() -> AllowanceSnapshot {
        let (directory, name) = splitPath(path)
        switch probe.probe(directory: directory, name: name, maxBytes: Self.maxFileBytes) {
        case .directoryFailed(.notFound):
            return .missing
        case .directoryFailed(.symbolicLink):
            return .invalid(.directorySymbolicLink)
        case .directoryFailed(.failed(let errno)):
            return .invalid(.directoryUnreadable(errno: errno))
        case .fileFailed(let directoryStatus, let error):
            if let reason = Self.directoryProblem(directoryStatus) { return .invalid(reason) }
            switch error {
            case .notFound: return .missing
            case .symbolicLink: return .invalid(.symbolicLink)
            case .failed(let errno): return .invalid(.unreadable(errno: errno))
            }
        case .opened(let directoryStatus, let fileStatus, let contents):
            if let reason = Self.directoryProblem(directoryStatus) ?? Self.fileProblem(fileStatus) {
                return .invalid(reason)
            }
            guard contents.count <= Self.maxFileBytes else { return .invalid(.tooLarge) }
            do throws(AllowanceInvalidReason) {
                let allowance = try Allowance(contents: contents)
                guard allowance.mac == mac else { return .invalid(.macMismatch) }
                return .allowance(allowance)
            } catch {
                return .invalid(error)
            }
        }
    }

    /// The verdict at `now` (contract 14.3): `not_before` less the skew tolerance is not later
    /// than `now`, and `now` is earlier than `expires_at`.
    public func verdict(for snapshot: AllowanceSnapshot, now: Timestamp) -> AllowanceVerdict {
        switch snapshot {
        case .missing: return .missing
        case .invalid(let reason): return .invalid(reason)
        case .allowance(let allowance):
            guard allowance.notBefore.adding(milliseconds: -Int64(skewToleranceMs)) <= now else {
                return .invalid(.notYetValid)
            }
            guard now < allowance.expiresAt else { return .invalid(.expired) }
            return .valid(expiresAt: allowance.expiresAt)
        }
    }

    /// Reads the file now and judges it at `now`, with no cache.
    public func verdict(now: Timestamp) -> AllowanceVerdict { verdict(for: read(), now: now) }

    private static func directoryProblem(_ status: AllowanceFileStatus) -> AllowanceInvalidReason? {
        guard status.kind == .directory else { return .directoryNotADirectory }
        guard status.owner == 0 else { return .directoryNotRootOwned(owner: status.owner) }
        guard !status.isWritableByGroupOrOthers else {
            return .directoryWritableByGroupOrOthers(permissions: status.permissions)
        }
        return nil
    }

    private static func fileProblem(_ status: AllowanceFileStatus) -> AllowanceInvalidReason? {
        guard status.kind == .regular else { return .notRegularFile }
        guard status.owner == 0 else { return .notRootOwned(owner: status.owner) }
        guard !status.isWritableByGroupOrOthers else {
            return .writableByGroupOrOthers(permissions: status.permissions)
        }
        return nil
    }
}

/// Answers from a copy of the allowance file's contents that is less than
/// ``maxAge`` old (`ALLOWANCE_CACHE_MAX_MS`, contract 14.4), so the file is read at most once per
/// second however many calls arrive. The copy holds the contents, not the verdict: every answer
/// compares `expires_at` with `now`, so the cache never delays an expiry.
///
/// A value type with one owner, the state's actor, which serializes every call.
public struct AllowanceCache: Sendable {
    /// `ALLOWANCE_CACHE_MAX_MS`.
    public static let maxAge: Duration = .milliseconds(ContractConstants.allowanceCacheMaxMs)

    public let reader: AllowanceReader
    private var copy: (snapshot: AllowanceSnapshot, readAt: ContinuousClock.Instant)?

    public init(reader: AllowanceReader) { self.reader = reader }

    /// The verdict at wall-clock `now`. `instant` is the monotonic time of the call and decides
    /// whether the copy is fresh enough; the file is read again when it is not.
    public mutating func verdict(now: Timestamp, at instant: ContinuousClock.Instant) -> AllowanceVerdict {
        reader.verdict(for: snapshot(at: instant), now: now)
    }

    /// Drops the copy so the next call reads the file, as when a watch reports a change.
    public mutating func invalidate() { copy = nil }

    private mutating func snapshot(at instant: ContinuousClock.Instant) -> AllowanceSnapshot {
        if let copy, copy.readAt <= instant, copy.readAt.duration(to: instant) < Self.maxAge {
            return copy.snapshot
        }
        let snapshot = reader.read()
        copy = (snapshot, instant)
        return snapshot
    }
}
