import Foundation

/// One reading of deskhand's two clocks, taken by the owner of the state and passed to logic.
///
/// The periods that bound unattended control, the lease and arming, run on ``monotonic``, which
/// never steps: a wall clock set back by a minute would otherwise lengthen both by a minute. ``wall``
/// is for what goes on the wire and for the allowance, whose times are wall-clock instants by
/// definition (contract 14.3). A wall-clock time shown for a monotonic deadline is computed from the
/// reading at hand, so it always agrees with `status.time`.
public struct ClockReading: Hashable, Sendable {
    public let wall: Timestamp
    public let monotonic: ContinuousClock.Instant

    public init(wall: Timestamp, monotonic: ContinuousClock.Instant) {
        self.wall = wall
        self.monotonic = monotonic
    }

    /// Reads both clocks now.
    public static func now() -> ClockReading {
        let monotonic = ContinuousClock.now
        let milliseconds = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        return ClockReading(wall: Timestamp(millisecondsSinceEpoch: Int64(milliseconds)), monotonic: monotonic)
    }

    /// The reading `milliseconds` later on both clocks, as if neither stepped.
    public func advanced(byMilliseconds milliseconds: Int64) -> ClockReading {
        ClockReading(
            wall: wall.adding(milliseconds: milliseconds),
            monotonic: monotonic.advanced(by: .milliseconds(milliseconds)))
    }

    /// The monotonic instant `milliseconds` from this reading.
    public func instant(afterMilliseconds milliseconds: Int64) -> ContinuousClock.Instant {
        monotonic.advanced(by: .milliseconds(milliseconds))
    }

    /// Whole milliseconds from this reading to `instant`, rounded up, never negative: `expires_in_ms`.
    public func milliseconds(until instant: ContinuousClock.Instant) -> Int {
        Int(max(0, signedMilliseconds(to: instant)))
    }

    /// The wall-clock time at which `instant` falls, judged from this reading.
    public func wallTime(at instant: ContinuousClock.Instant) -> Timestamp {
        wall.adding(milliseconds: signedMilliseconds(to: instant))
    }

    /// The monotonic instant at which the wall clock reads `time`, if it does not step meanwhile.
    public func instant(atWallTime time: Timestamp) -> ContinuousClock.Instant {
        instant(afterMilliseconds: time.millisecondsSinceEpoch - wall.millisecondsSinceEpoch)
    }

    private func signedMilliseconds(to instant: ContinuousClock.Instant) -> Int64 {
        Int64((monotonic.duration(to: instant) / .milliseconds(1)).rounded(.up))
    }
}
