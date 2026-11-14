/// What the watchdog asked to stop the call in the admission section with, until that call leaves
/// (contract 12.4, 13). A lease end is kept by the lease it ended and applies only to a call that
/// runs under that lease, so the end of another lease never hides an interruption that applies.
struct PendingInterruptions: Sendable {
    /// The first, in the order of contract 9.5, of those that stop whichever call is in the section.
    private var standing: Interruption?
    /// The first end of each lease, by serial.
    private var leaseEnds: [UInt64: LeaseEnd] = [:]

    mutating func add(_ interruption: Interruption) {
        switch interruption {
        case .leaseEnded(let end):
            if leaseEnds[end.lease.serial] == nil { leaseEnds[end.lease.serial] = end }
        case .state, .userActive:
            if let standing, standing.reason.abortRank <= interruption.reason.abortRank { return }
            standing = interruption
        }
    }

    /// The first cause, in the order of contract 9.5, that applies to a call running under `lease`.
    func cause(under lease: Lease) -> ToolErrorReason? {
        .first(standing?.reason, leaseEnds[lease.serial]?.cause.abortReason)
    }
}
