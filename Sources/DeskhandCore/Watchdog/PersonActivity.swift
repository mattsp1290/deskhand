import Synchronization

/// When deskhand last posted an input event, so that its own events can be told from the person's
/// (contract 13.2).
public protocol PostTimestampProvider: Sendable {
    /// On the monotonic clock; `nil` before the first.
    var lastPostedEvent: ContinuousClock.Instant? { get }
}

/// A ``PostTimestampProvider`` that the app's ``ExecutorObserver`` feeds from
/// ``ExecutorObserver/didPostEvent(at:)``. Safe to call from the executor without waiting.
public final class PostTimestampRecorder: PostTimestampProvider {
    private let last = Mutex<ContinuousClock.Instant?>(nil)

    public init() {}

    public var lastPostedEvent: ContinuousClock.Instant? { last.withLock { $0 } }

    /// Never moves back: a report that arrives late does not hide a later post.
    public func didPostEvent(at instant: ContinuousClock.Instant) {
        last.withLock { last in last = max(last ?? instant, instant) }
    }
}

/// One reading of the platform's hardware-input idle signal. Which signal macOS offers, and so
/// which case the platform reports, is the spike's choice (contract 13.2).
public enum IdleSignal: Hashable, Sendable {
    /// The signal could not be read.
    case unavailable
    /// Time since the person's last keyboard or pointer input. deskhand's own events never reset
    /// it: the platform has already told them apart.
    case personOnly(Duration)
    /// Time since the last keyboard or pointer input of any origin, deskhand's own events included.
    case anyOrigin(Duration)
}

/// The platform's idle signal, read afresh on every call. It must answer without waiting: the
/// executor reads it between the checks and the post of an event.
public protocol IdleSignalSource: Sendable {
    func idleSignal() -> IdleSignal
}

/// How long the person at the Mac has been idle, as far as deskhand can tell (contract 11.5, 13.2).
public enum PersonIdleRule {
    /// The person's idle time at `now`, or `nil` when it cannot be told, which counts as activity.
    ///
    /// A ``IdleSignal/personOnly(_:)`` reading is the answer. An ``IdleSignal/anyOrigin(_:)``
    /// reading is the person's only when its latest input came more than `echoTolerance` after
    /// deskhand's last post. Otherwise that input may be deskhand's own, and the person's input,
    /// made while deskhand posted, is hidden behind deskhand's next event, so the two cannot be
    /// separated: inside `lookback` that is activity, and beyond it nobody produced any input at
    /// all. With such a signal an effect within `lookback` of deskhand's last post is therefore
    /// refused or aborted.
    public static func personIdle(
        _ signal: IdleSignal, lastOwnPost: ContinuousClock.Instant?, now: ContinuousClock.Instant,
        echoTolerance: Duration, lookback: Duration
    ) -> Duration? {
        switch signal {
        case .unavailable:
            return nil
        case .personOnly(let idle):
            return max(.zero, idle)
        case .anyOrigin(let idle):
            let idle = max(.zero, idle)
            let latestInput = now.advanced(by: .zero - idle)
            guard let lastOwnPost, latestInput <= lastOwnPost.advanced(by: echoTolerance) else { return idle }
            return idle >= lookback ? idle : nil
        }
    }
}

/// The executor's and the watchdog's ``UserActivitySource``: the platform's idle signal with
/// deskhand's own posts discounted by ``PersonIdleRule``. Build the executor with it, so the
/// refusal before admission and the checks before every event apply the same rule as the
/// watchdog's poll.
public struct PersonActivitySource: UserActivitySource {
    /// How long after deskhand reports a post the idle signal may still show that post as the
    /// latest input. It must cover the time from the check before an event to its post, and the
    /// platform's latency; the spike measures both.
    public static let defaultEchoTolerance: Duration = .milliseconds(50)

    private let signal: any IdleSignalSource
    private let posts: any PostTimestampProvider
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let echoTolerance: Duration

    /// `clock` reads the monotonic clock at the moment the signal is read.
    public init(
        signal: any IdleSignalSource, posts: any PostTimestampProvider,
        echoTolerance: Duration = PersonActivitySource.defaultEchoTolerance,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.signal = signal
        self.posts = posts
        self.clock = clock
        self.echoTolerance = echoTolerance
    }

    /// Whole milliseconds, rounded down, so an idle time just short of the lookback stays under it.
    public func idleMilliseconds() -> Int? {
        let reading = signal.idleSignal()
        let idle = PersonIdleRule.personIdle(
            reading, lastOwnPost: posts.lastPostedEvent, now: clock(), echoTolerance: echoTolerance,
            lookback: .milliseconds(ContractConstants.userActivityLookbackMs))
        return idle.map { Int(($0 / .milliseconds(1)).rounded(.down)) }
    }
}
