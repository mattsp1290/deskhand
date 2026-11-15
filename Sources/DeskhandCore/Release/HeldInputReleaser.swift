/// The releases of contract 12.4 step 2, 12.7 and 12.8, as the executor's ``ReleaseHandler``: a
/// key-up or a button-up for each input the ledger records, newest first, each one only while
/// cleanup is authorized, and each entry cleared only after its release went out.
public struct HeldInputReleaser: ReleaseHandler {
    public init() {}

    /// Releases those of `inputs` that `ledger` records, in the reverse of the order the ledger
    /// recorded them. An entry that is not among `inputs`, such as another operation's, is neither
    /// posted nor cleared (contract 12.7 item 4), and an input the ledger does not record is owed
    /// nothing: the ledger, not the caller's count, decides what is released.
    ///
    /// It asks `authorization` before each release and stops at the first denial, and it stops at
    /// the first release that cannot be posted. Either way the rest stay in the ledger, and a later
    /// attempt starts again from the newest. A clear that fails does not stop it, because the
    /// releases still to come remove input; that entry stays, and the ledger is unavailable until
    /// it is read again. ``CleanupOutcome/complete`` means that every one of `inputs` the ledger
    /// recorded was released and cleared.
    public func release(
        _ inputs: [HeldInput], from ledger: inout HeldInputLedger, poster: any EventPoster,
        authorization: () -> CleanupAuthorization
    ) -> CleanupOutcome {
        ledger.releasePending(inputs, authorization: authorization, postRelease: poster.postRelease)
    }
}
