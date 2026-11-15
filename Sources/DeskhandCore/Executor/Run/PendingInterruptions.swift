struct PendingInterruptions: Sendable {
    private var standing: Interruption?
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

    func cause(under lease: Lease) -> ToolErrorReason? {
        .first(standing?.reason, leaseEnds[lease.serial]?.cause.abortReason)
    }
}
