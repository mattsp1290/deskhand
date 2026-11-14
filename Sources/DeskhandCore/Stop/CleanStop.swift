/// The executor as a process stop drives it. ``InputExecutor`` conforms.
public protocol StoppableExecutor: Sendable {
    /// ``InputExecutor/stop()``.
    func stop() async -> ExecutorStop
}

extension InputExecutor: StoppableExecutor {}

/// The rest of deskhand as a process stop drives it (contract 15.2): the listener, the state owner
/// and deskhand's own log.
public protocol CleanStopHost: Sendable {
    /// Step 1: stop accepting connections and read no further request from those that are open,
    /// and cancel the watchdog's task. Must not wait for calls in flight.
    func stopAcceptingCalls() async

    /// Drops the lease and every frame, so nothing answered before the exit names them; the next
    /// start begins with neither (contract 12.9 step 3, 15.2).
    func dropLeaseAndFrames() async

    /// Step 4's log of the stop itself. Must not wait: it runs once the bound has passed too.
    func logStop(_ report: CleanStopReport)

    /// Step 5: lets read calls in flight finish, then closes every connection.
    func closeConnections() async
}

/// What a process stop did, for its log entry.
public struct CleanStopReport: Hashable, Sendable {
    /// `nil` when the executor had not answered by the bound: a call before admission was still
    /// waiting on the action log, a frame check or a patch recapture. Whatever reached the disk is
    /// what the next start recovers (contract 12.9).
    public let executor: ExecutorStop?
    /// The lease and the frames were dropped before the bound.
    public let leaseDropped: Bool
    /// From the start of the stop to the log of it.
    public let elapsed: Duration

    public init(executor: ExecutorStop?, leaseDropped: Bool, elapsed: Duration) {
        self.executor = executor
        self.leaseDropped = leaseDropped
        self.elapsed = elapsed
    }
}

/// The process stop of contract 15.2, which `SIGTERM` starts: it stops taking calls, ends the
/// operation in flight through ``StoppableExecutor/stop()``, drops the lease and the frames, logs
/// the stop, lets read calls finish, and exits with status 0. Every wait races one deadline,
/// `DEADLINE_BOUND_MS` after the stop began, and the exit follows it whatever is still waiting.
///
/// The stop runs once. A second ``stop()``, as from a second `SIGTERM`, waits for the first and
/// changes nothing.
public actor CleanStop {
    public static let exitStatus: Int32 = 0

    private let executor: any StoppableExecutor
    private let host: any CleanStopHost
    private let scheduler: any WatchdogScheduler
    private let bound: Duration
    private let exit: @Sendable (Int32) -> Void
    private var running: Task<CleanStopReport, Never>?

    /// `exit` ends the process; in deskhand it does not return.
    public init(
        executor: any StoppableExecutor, host: any CleanStopHost,
        scheduler: any WatchdogScheduler = ContinuousClockScheduler(),
        bound: Duration = .milliseconds(ContractConstants.deadlineBoundMs),
        exit: @escaping @Sendable (Int32) -> Void
    ) {
        self.executor = executor
        self.host = host
        self.scheduler = scheduler
        self.bound = bound
        self.exit = exit
    }

    /// Stops deskhand and exits. Returns the report it logged, only when `exit` returns, as a
    /// test's does.
    @discardableResult
    public func stop() async -> CleanStopReport {
        if let running { return await running.value }
        let (executor, host, scheduler, exit) = (self.executor, self.host, self.scheduler, self.exit)
        let start = scheduler.now
        let deadline = start.advanced(by: bound)
        let task = Task {
            let ended = await Self.within(deadline, on: scheduler) { () async -> ExecutorStop in
                await host.stopAcceptingCalls()
                return await executor.stop()
            }
            let dropped = await Self.within(deadline, on: scheduler) { await host.dropLeaseAndFrames() } != nil
            let report = CleanStopReport(
                executor: ended, leaseDropped: dropped, elapsed: start.duration(to: scheduler.now))
            host.logStop(report)
            // Past the bound the exit closes what is still open.
            _ = await Self.within(deadline, on: scheduler) { await host.closeConnections() }
            exit(Self.exitStatus)
            return report
        }
        running = task
        return await task.value
    }

    /// `operation`'s answer, or `nil` once `deadline` passed first. The operation runs in a task of
    /// its own and is left to finish unobserved.
    private static func within<T: Sendable>(
        _ deadline: ContinuousClock.Instant, on scheduler: any WatchdogScheduler,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        guard scheduler.now < deadline else { return nil }
        return await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            let timeout = Task {
                await scheduler.sleep(until: deadline)
                answer.resume(returning: nil)
            }
            Task {
                answer.resume(returning: await operation())
                timeout.cancel()
            }
        }
    }
}
