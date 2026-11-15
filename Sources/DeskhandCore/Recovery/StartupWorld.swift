/// What deskhand holds in memory when it starts, whatever the previous run held (contract 10.1,
/// 12.9 steps 3 and 4): no frame, no lease, `disarmed`, and neither arming nor `paused` carried
/// over. The owners of the state, the lease and the frames start from it.
public struct StartupWorld: Sendable {
    /// `status.started_at`.
    public let startedAt: Timestamp
    /// ``StateReport/startup``: `disarmed` with nothing read yet. Seed the first reduction with it.
    public let report: StateReport
    /// No lease, and none that ran out: `lease_expired` applies to nobody.
    public let lease: LeaseManager
    /// Every frame of the previous run is gone.
    public let frames: FrameStore

    public init(startedAt: Timestamp) {
        self.startedAt = startedAt
        report = .startup
        lease = LeaseManager()
        frames = FrameStore()
    }
}
