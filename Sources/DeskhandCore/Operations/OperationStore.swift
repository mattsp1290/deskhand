/// The durable operation records (contract 12): admission, the lifecycle, retention, the cap per
/// principal and restart recovery.
///
/// The file is an append-only journal (``OperationJournal``) rather than a rewritten snapshot,
/// because a transition then costs one short line and one flush instead of rewriting up to
/// 10,000 records per principal before every first event. Loading replays it, applies the
/// restart rules and rewrites it atomically, which also drops expired records and a torn tail.
///
/// Not `Sendable`: one owner, the effect executor, makes every call in turn, so the record lookup
/// at refusal step 3, the capacity check at step 8 and admission after step 15 (contract 9.5) see
/// one consistent store.
///
/// Every call either takes full effect, durably where the contract asks for it, or throws and
/// leaves the records as they were. After a failed write the store is ``isAvailable`` `false`:
/// it refuses every call until a new store is loaded from the storage, which applies the restart
/// rules to whatever reached the disk.
public final class OperationStore {
    public struct Configuration: Hashable, Sendable {
        /// `OPERATION_RETENTION_MS`, measured from admission.
        public var retentionMs: Int
        /// `OPERATION_MAX_RECORDS`, counted per principal across its `holder_id` values.
        public var maxRecordsPerPrincipal: Int
        /// The journal is rewritten once this many entries, or four per record if that is more,
        /// have been appended since it was last rewritten.
        public var compactAfterEntries: Int

        public init(
            retentionMs: Int = ContractConstants.defaultOperationRetentionMs,
            maxRecordsPerPrincipal: Int = ContractConstants.defaultOperationMaxRecords,
            compactAfterEntries: Int = 4096
        ) {
            self.retentionMs = retentionMs
            self.maxRecordsPerPrincipal = maxRecordsPerPrincipal
            self.compactAfterEntries = compactAfterEntries
        }

        public init(limits: Limits) {
            self.init(retentionMs: limits.operationRetentionMs, maxRecordsPerPrincipal: limits.operationMaxRecords)
        }
    }

    private struct Admission {
        let key: OperationKey
        let admittedAt: Timestamp
    }

    public let configuration: Configuration
    private let storage: any OperationStorage
    private var records: [OperationKey: OperationRecord] = [:]
    /// Sorted by admission time, so the records that have left the window are a prefix.
    private var admissions: [Admission] = []
    private var countByPrincipal: [Principal: Int] = [:]
    private var entriesSinceSnapshot = 0
    public private(set) var isAvailable = true

    /// Loads the records and applies the restart rules (contract 12.9): `accepted` becomes
    /// `failed_before_execution` and `executing` becomes `aborted_by_restart` with the last count on
    /// disk. The result is written back durably before this returns. Records that left the
    /// retention window by `now` are dropped.
    public init(
        storage: any OperationStorage, configuration: Configuration = Configuration(), now: Timestamp
    ) throws(OperationStoreLoadError) {
        self.storage = storage
        self.configuration = configuration
        let bytes: [UInt8]?
        do throws(StorageError) {
            bytes = try storage.read()
        } catch {
            throw .unreadable(error)
        }
        if let bytes { records = try OperationJournal.replay(bytes) }
        for (key, record) in records where !record.phase.isFinal {
            records[key]?.phase = record.phase.applying(.restart)!
        }
        for record in records.values { countByPrincipal[record.key.principal, default: 0] += 1 }
        admissions = records.values.map { Admission(key: $0.key, admittedAt: $0.admittedAt) }
            .sorted { $0.admittedAt < $1.admittedAt }
        prune(now)
        do throws(StorageError) {
            try storage.replace(with: snapshot())
        } catch {
            throw .notWritable(error)
        }
    }

    /// The record for `key`, if one is inside the retention window. For the `operation` member of a
    /// state's refusal (contract 4.3), which carries the record whatever the digest.
    public func record(for key: OperationKey, now: Timestamp) throws(OperationStoreError) -> OperationRecord? {
        try requireAvailable()
        prune(now)
        return records[key]
    }

    /// Refusal step 3 (contract 9.5): what a call gets when its `operation_id` already has a record.
    public func lookup(_ key: OperationKey, digest: RequestDigest, now: Timestamp) throws(OperationStoreError)
        -> OperationLookup
    {
        OperationLookup(try record(for: key, now: now), digest: digest)
    }

    /// How many records `principal` has inside the retention window, across all its holders.
    public func recordCount(for principal: Principal, now: Timestamp) throws(OperationStoreError) -> Int {
        try requireAvailable()
        prune(now)
        return countByPrincipal[principal, default: 0]
    }

    /// Refusal step 8 (contract 9.5): `false` means a new `operation_id` gets `operation_capacity`.
    public func hasCapacity(for principal: Principal, now: Timestamp) throws(OperationStoreError) -> Bool {
        try recordCount(for: principal, now: now) < configuration.maxRecordsPerPrincipal
    }

    /// Creates the record as `accepted` (contract 12.3 step 3), or says why not. The record is keyed
    /// by the intent the receipt proves committed, so no record exists without its intent entry
    /// (steps 2 and 3). An existing record is answered first, so a repeat is answered even at the
    /// cap. Call it once every refusal check has passed and the caller's connection is still open;
    /// nothing is created otherwise. When this does not answer ``OperationAdmission/new(_:)``, or
    /// throws, the intent entry stands alone, and the call's refusal entry says why (contract 12.10).
    public func admit(_ receipt: IntentReceipt, digest: RequestDigest, now: Timestamp) throws(OperationStoreError)
        -> OperationAdmission
    {
        let intent = receipt.intent
        let key = OperationKey(principal: intent.principal, holderID: intent.holderID, operationID: intent.operationID)
        switch try lookup(key, digest: digest, now: now) {
        case .conflict(let view): return .conflict(view)
        case .inProgress(let view): return .inProgress(view)
        case .replay(let replay): return .replay(replay)
        case .absent: break
        }
        guard countByPrincipal[key.principal, default: 0] < configuration.maxRecordsPerPrincipal else {
            return .capacity
        }
        if entriesSinceSnapshot >= max(configuration.compactAfterEntries, 4 * records.count) {
            try compact()
        }
        let record = OperationRecord(key: key, digest: digest, admittedAt: now, phase: .accepted)
        try write(.record(record), for: key)
        insert(record)
        return .new(OperationTicket(key: key, admittedAt: now))
    }

    /// Records `executing`, durably, before the first event is posted (contract 12.3 step 4). If
    /// this throws, post nothing and answer `internal_error`; while the store is still available,
    /// also ``finish(_:_:eventsPosted:)`` the operation as `failed`.
    public func markExecuting(_ ticket: OperationTicket) throws(OperationStoreError) {
        try advance(ticket, .execute)
    }

    /// Records how many events have been posted so far, durably. Optional: it only makes the count
    /// that a crash leaves behind for `aborted_by_restart` less of an underestimate.
    public func recordProgress(_ ticket: OperationTicket, eventsPosted: Int) throws(OperationStoreError) {
        try advance(ticket, .progress(eventsPosted: eventsPosted))
    }

    /// Records the final status, `events_posted` and the result, durably, before the response is
    /// sent (contract 12.3 step 7). The store sets the result's `operation_id`, count and
    /// `replayed: false`, and an error's `measured`; send what this returns, so that a repeat gets
    /// the same result.
    ///
    /// From `accepted` only `aborted` or `failed` with no events is allowed: an operation that
    /// stopped before its first event.
    public func finish(_ ticket: OperationTicket, _ outcome: OperationOutcome, eventsPosted: Int)
        throws(OperationStoreError) -> OperationOutcome
    {
        let stamped = outcome.stamped(for: ticket.key, eventsPosted: eventsPosted)
        try advance(ticket, .finish(stamped.ending, eventsPosted: eventsPosted))
        return stamped
    }

    /// A clean stop (contract 15.2): an `accepted` record becomes `failed_before_execution` and an
    /// `executing` one `aborted_by_restart` with the exact count, durably.
    public func interrupt(_ ticket: OperationTicket, eventsPosted: Int) throws(OperationStoreError) {
        try advance(ticket, .interrupt(eventsPosted: eventsPosted))
    }

    private func advance(_ ticket: OperationTicket, _ transition: OperationTransition) throws(OperationStoreError) {
        try requireAvailable()
        guard var record = records[ticket.key], record.admittedAt == ticket.admittedAt else {
            throw .unknownOperation(ticket.key)
        }
        guard let next = record.phase.applying(transition) else {
            throw .illegalTransition(ticket.key, from: record.phase.status)
        }
        try write(.transition(ticket.key, transition), for: ticket.key)
        record.phase = next
        records[ticket.key] = record
    }

    private func requireAvailable() throws(OperationStoreError) {
        guard isAvailable else { throw .unavailable }
    }

    private func write(_ entry: OperationJournal.Entry, for key: OperationKey) throws(OperationStoreError) {
        let line: [UInt8]
        do throws(NonFiniteNumberError) {
            line = try entry.line()
        } catch {
            throw .unencodableResult(key)
        }
        do throws(StorageError) {
            try storage.append(line)
            try storage.synchronize()
        } catch {
            isAvailable = false
            throw .writeFailed(error)
        }
        entriesSinceSnapshot += 1
    }

    private func compact() throws(OperationStoreError) {
        do throws(StorageError) {
            try storage.replace(with: snapshot())
        } catch {
            isAvailable = false
            throw .writeFailed(error)
        }
        entriesSinceSnapshot = 0
    }

    private func snapshot() -> [UInt8] {
        let ordered = admissions.compactMap { records[$0.key] }
        // Every stored result was encoded once already, when it was journaled.
        return try! OperationJournal.snapshot(ordered)
    }

    private func insert(_ record: OperationRecord) {
        records[record.key] = record
        countByPrincipal[record.key.principal, default: 0] += 1
        let admission = Admission(key: record.key, admittedAt: record.admittedAt)
        if let last = admissions.last, last.admittedAt > record.admittedAt {
            let index = admissions.partitioningIndex { $0.admittedAt > record.admittedAt }
            admissions.insert(admission, at: index)
        } else {
            admissions.append(admission)
        }
    }

    /// Deletes the final records whose window has passed (contract 12.6). A record still
    /// `accepted` or `executing` stays whatever its age: its executor still holds a ticket.
    private func prune(_ now: Timestamp) {
        let horizon = Int64(configuration.retentionMs)
        var kept: [Admission] = []
        var end = admissions.startIndex
        while end < admissions.endIndex,
            now.millisecondsSinceEpoch - admissions[end].admittedAt.millisecondsSinceEpoch >= horizon
        {
            let admission = admissions[end]
            end += 1
            guard let record = records[admission.key], record.admittedAt == admission.admittedAt else { continue }
            if record.phase.isFinal {
                records[admission.key] = nil
                countByPrincipal[admission.key.principal, default: 1] -= 1
                if countByPrincipal[admission.key.principal] == 0 { countByPrincipal[admission.key.principal] = nil }
            } else {
                kept.append(admission)
            }
        }
        if end > admissions.startIndex { admissions.replaceSubrange(admissions.startIndex..<end, with: kept) }
    }
}

extension Array {
    /// The first index whose element satisfies `belongsInSecondPartition`, which must be false for
    /// a prefix of the array and true for the rest.
    fileprivate func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if belongsInSecondPartition(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
