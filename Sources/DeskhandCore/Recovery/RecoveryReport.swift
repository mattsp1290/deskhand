/// What a start recovered, and what effect calls get because of it (contract 12.9).
public struct RecoveryReport: Sendable, CustomStringConvertible {
    public let operationRecords: OperationRecordsRecovery
    public let heldInputLedger: HeldInputLedgerRecovery
    /// The first attempt at the releases the ledger holds.
    public let cleanup: OwedRelease
    /// What every effect call is refused with after recovery, apart from a blocking state:
    /// `internal_error` while a store is unavailable, `cleanup_pending` while releases are still
    /// owed (contract 9.5 steps 4 and 5). `nil` when neither holds.
    public let effectRefusal: ToolErrorCode?

    public var description: String {
        let effects = effectRefusal.map { "refused with \($0.rawValue)" } ?? "not refused by recovery"
        return "\(operationRecords); \(heldInputLedger); cleanup: \(cleanup.summary); effects: \(effects)"
    }
}

/// The operation records at start.
public enum OperationRecordsRecovery: Sendable, CustomStringConvertible {
    /// Loaded, with the restart rules written back durably. `restarted` holds every record the
    /// previous run left `accepted` or `executing`, with its status now.
    case loaded(restarted: [OperationKey: OperationStatus])
    /// Not loaded: every effect call is refused with `internal_error` until a reload succeeds.
    case unavailable(OperationStoreLoadError)

    public var restarted: [OperationKey: OperationStatus] {
        if case .loaded(let restarted) = self { restarted } else { [:] }
    }

    /// How many records loading ended with `status`: `failed_before_execution` or
    /// `aborted_by_restart`.
    public func count(of status: OperationStatus) -> Int { restarted.values.count { $0 == status } }

    public var description: String {
        switch self {
        case .loaded:
            "operation records: \(count(of: .failedBeforeExecution)) failed_before_execution, "
                + "\(count(of: .abortedByRestart)) aborted_by_restart"
        case .unavailable(let error): "operation records unavailable: \(error)"
        }
    }
}

/// The held-input ledger at start.
public enum HeldInputLedgerRecovery: Sendable, CustomStringConvertible {
    /// What the previous run left, in press order. Each entry may still be down and is owed a
    /// release.
    case loaded(left: [HeldInput])
    /// Not read: every effect call is refused with `internal_error` until a reload reads it.
    case unavailable(HeldInputLedgerError)

    public var description: String {
        switch self {
        case .loaded(let left): "held-input ledger: \(left.count) entries left"
        case .unavailable(let error): "held-input ledger unavailable: \(error)"
        }
    }
}

extension OwedRelease {
    fileprivate var summary: String {
        switch self {
        case .nothingOwed: "nothing owed"
        case .operationInSection: "an operation is in the admission section"
        case .attempted(.complete): "every release posted"
        case .attempted(.deferred(let blockers)):
            "deferred while \(blockers.map(\.rawValue).sorted().joined(separator: ", "))"
        case .attempted(.postFailed(let input, let error)): "release of \(input) failed: \(error)"
        case .attempted(.clearFailed(let error)): "releases posted, ledger not cleared: \(error)"
        }
    }
}
