public enum HeldInputLedgerError: Error, CustomStringConvertible {
    case readFailed(any Error)
    /// The guarded event must not be posted. The ledger is unavailable from now on.
    case writeFailed(any Error)
    /// An earlier write failed, so the file may not hold what the ledger holds. Nothing is written
    /// until ``HeldInputLedger/reload()``, and the guarded event must not be posted.
    case unavailable
    /// The stored bytes are not a ledger this version reads.
    case corrupt(String)

    public var description: String {
        switch self {
        case .readFailed(let error): "held-input ledger could not be read: \(error)"
        case .writeFailed(let error): "held-input ledger could not be written: \(error)"
        case .unavailable: "held-input ledger is unavailable after a failed write"
        case .corrupt(let reason): "held-input ledger is corrupt: \(reason)"
        }
    }
}

/// How ``HeldInputLedger/releasePending(authorization:postRelease:)`` ended.
public enum CleanupOutcome: Sendable {
    /// Every entry was released and cleared. The ledger and its file are empty.
    case complete
    /// Authorization was denied before the next release. Nothing more was posted.
    case deferred(Set<CleanupBlocker>)
    /// Posting this input's release failed. Its entry and every older one stay, and nothing more
    /// was posted.
    case postFailed(HeldInput, any Error)
    /// Every release was posted, but the file may still hold entries: a clear failed, or the ledger
    /// was already unavailable. ``HeldInputLedger/reload()``, then clean up again; the entries left
    /// get their releases posted a second time, which does no harm.
    case clearFailed(HeldInputLedgerError)
}

/// The durable record of every key and button that might be down because deskhand pressed it
/// (contract 12.7). Noncopyable so that exactly one value, held by whoever posts input, writes the
/// store.
///
/// Durable storage holds a superset of what is down: an entry is written before its down event
/// and cleared after its up event. Recovery therefore releases too much, never too little.
///
/// A failed write can still have reached the store, so after one the ledger no longer knows what
/// is durable. It is then ``isAvailable`` `false`: it writes nothing and refuses every press until
/// ``reload()`` reads the store again. Its entries still include everything that is down, so
/// ``releasePending(authorization:postRelease:)`` still posts their releases.
public struct HeldInputLedger: ~Copyable {
    private let store: any HeldInputStore
    private var entries: [HeldInput]
    /// `false` after a failed write, until ``reload()``. While it is `false` every effect call is
    /// refused with `internal_error` (contract 12.3).
    public private(set) var isAvailable = true

    /// Opens the ledger with what the previous run left in `store`. Every entry may still be down.
    public init(store: any HeldInputStore) throws(HeldInputLedgerError) {
        entries = try Self.load(store)
        self.store = store
    }

    /// Entries in press order. Non-empty with no operation executing means `cleanup_pending`.
    public func pending() -> [HeldInput] { entries }

    /// Records `input` as possibly held and makes that durable. Post its down event only after this
    /// returns; if it throws, post nothing. An input already recorded keeps its place.
    public mutating func willPress(_ input: HeldInput) throws(HeldInputLedgerError) {
        guard isAvailable else { throw .unavailable }
        guard !entries.contains(input) else { return }
        try persist(entries + [input])
        entries.append(input)
    }

    /// Clears `input` after its up event was posted, durably. If this throws, the entry stays, the
    /// ledger is unavailable, and a later cleanup posts that release again. An input not recorded
    /// is ignored.
    public mutating func didRelease(_ input: HeldInput) throws(HeldInputLedgerError) {
        guard isAvailable else { throw .unavailable }
        guard let index = entries.firstIndex(of: input) else { return }
        var remaining = entries
        remaining.remove(at: index)
        try persist(remaining)
        entries = remaining
    }

    /// Reads the store again and makes the ledger available. As at a start, every entry it then
    /// holds may be down. If this throws, the ledger stays as it was.
    public mutating func reload() throws(HeldInputLedgerError) {
        entries = try Self.load(store)
        isAvailable = true
    }

    /// Releases every entry, newest first, posting only the matching up events. Before each one it
    /// asks `authorization`, and stops at the first denial or failed post. A failed clear does not
    /// stop it: the remaining releases still remove input, and the uncleared entries stay.
    ///
    /// An operation never starts while the ledger has entries (`cleanup_pending` refuses it), so on
    /// an abort the entries are exactly what the aborted operation pressed.
    public mutating func releasePending(
        authorization: () -> CleanupAuthorization, postRelease: (HeldInput) throws -> Void
    ) -> CleanupOutcome {
        var clearFailure: HeldInputLedgerError?
        for input in Array(entries.reversed()) {
            if case .deferred(let blockers) = authorization() { return .deferred(blockers) }
            do { try postRelease(input) } catch { return .postFailed(input, error) }
            do { try didRelease(input) } catch { clearFailure = clearFailure ?? error }
        }
        if let clearFailure { return .clearFailed(clearFailure) }
        return isAvailable ? .complete : .clearFailed(.unavailable)
    }

    private static func load(_ store: any HeldInputStore) throws(HeldInputLedgerError) -> [HeldInput] {
        let bytes: [UInt8]?
        do { bytes = try store.load() } catch { throw .readFailed(error) }
        guard let bytes else { return [] }
        return try HeldInputLedgerFormat.decode(bytes)
    }

    private mutating func persist(_ next: [HeldInput]) throws(HeldInputLedgerError) {
        do {
            try store.replace(with: HeldInputLedgerFormat.encode(next))
        } catch {
            isAvailable = false
            throw .writeFailed(error)
        }
    }
}
