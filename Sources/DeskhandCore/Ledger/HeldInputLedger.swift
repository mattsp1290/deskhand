public enum HeldInputLedgerError: Error, CustomStringConvertible {
    case readFailed(any Error)
    /// The guarded event must not be posted.
    case writeFailed(any Error)
    /// The stored bytes are not a ledger this version reads.
    case corrupt(String)

    public var description: String {
        switch self {
        case .readFailed(let error): "held-input ledger could not be read: \(error)"
        case .writeFailed(let error): "held-input ledger could not be written: \(error)"
        case .corrupt(let reason): "held-input ledger is corrupt: \(reason)"
        }
    }
}

/// How ``HeldInputLedger/releasePending(authorization:postRelease:)`` ended.
public enum CleanupOutcome: Sendable {
    /// Every entry was released and cleared. The ledger is empty.
    case complete
    /// Authorization was denied before the next release. Nothing more was posted.
    case deferred(Set<CleanupBlocker>)
    /// Posting this input's release failed. Its entry and every older one stay, and nothing more
    /// was posted.
    case postFailed(HeldInput, any Error)
    /// Every release was posted, but at least one clear did not reach storage. Those entries
    /// stay, so a later cleanup posts their releases again.
    case clearFailed(HeldInputLedgerError)
}

/// The durable record of every key and button that might be down because deskhand pressed it
/// (contract 12.7). Noncopyable so that exactly one value, held by whoever posts input, writes the
/// store.
///
/// Durable storage holds a superset of what is down: an entry is written before its down event
/// and cleared after its up event. Recovery therefore releases too much, never too little.
public struct HeldInputLedger: ~Copyable {
    private let store: any HeldInputStore
    private var entries: [HeldInput]

    /// Opens the ledger with what the previous run left in `store`. Every entry may still be down.
    public init(store: any HeldInputStore) throws(HeldInputLedgerError) {
        let bytes: [UInt8]?
        do { bytes = try store.load() } catch { throw .readFailed(error) }
        let recovered = try bytes.map { bytes throws(HeldInputLedgerError) in try HeldInputLedgerFormat.decode(bytes) }
        self.store = store
        entries = recovered ?? []
    }

    /// Entries in press order. Non-empty with no operation executing means `cleanup_pending`.
    public func pending() -> [HeldInput] { entries }

    /// Records `input` as possibly held and makes that durable. Post its down event only after this
    /// returns; if it throws, post nothing. An input already recorded keeps its place.
    public mutating func willPress(_ input: HeldInput) throws(HeldInputLedgerError) {
        guard !entries.contains(input) else { return }
        try persist(entries + [input])
        entries.append(input)
    }

    /// Clears `input` after its up event was posted, durably. If this throws, the entry stays and a
    /// later cleanup posts that release again. An input not recorded is ignored.
    public mutating func didRelease(_ input: HeldInput) throws(HeldInputLedgerError) {
        guard let index = entries.firstIndex(of: input) else { return }
        var remaining = entries
        remaining.remove(at: index)
        try persist(remaining)
        entries = remaining
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
        return clearFailure.map(CleanupOutcome.clearFailed) ?? .complete
    }

    private func persist(_ next: [HeldInput]) throws(HeldInputLedgerError) {
        do { try store.replace(with: HeldInputLedgerFormat.encode(next)) } catch { throw .writeFailed(error) }
    }
}
