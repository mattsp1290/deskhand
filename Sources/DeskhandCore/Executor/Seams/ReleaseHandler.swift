/// Posts the releases an operation owes: at its abort, and later for releases that had to wait
/// (contract 12.4, 12.7, 12.8). The executor owns the ledger and lends it for the call.
public protocol ReleaseHandler: Sendable {
    /// Releases `inputs`, which are in press order and all in `ledger`, in the reverse of that
    /// order. Before each release it asks `authorization`, and stops at the first denial: the rest
    /// wait in the ledger. A release is a key-up or a button-up where the pointer is, and its entry
    /// is cleared only after it was posted.
    func release(
        _ inputs: [HeldInput], from ledger: inout HeldInputLedger, poster: any EventPoster,
        authorization: () -> CleanupAuthorization
    ) -> CleanupOutcome
}
