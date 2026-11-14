/// The executor as a process stop drives it. ``InputExecutor`` conforms.
public protocol StoppableExecutor: Sendable {
    /// ``InputExecutor/beginStop()``.
    func beginStop() async
    /// ``InputExecutor/stop()``.
    func stop() async -> ExecutorStop
    /// ``InputExecutor/awaitStopEntries()``.
    func awaitStopEntries() async -> Bool?
}

extension InputExecutor: StoppableExecutor {}

/// The rest of deskhand as a process stop drives it (contract 15.2): the listener, the state owner
/// and deskhand's own log.
///
/// An effect call the stop ended, and every effect call after it, gets no response: the MCP layer
/// closes its connection without writing one. Read calls in flight are answered.
public protocol CleanStopHost: Sendable {
    /// Step 1: stop accepting connections and read no further request from those that are open,
    /// and cancel the watchdog's task. Must not wait for calls in flight, and should not close the
    /// open connections, so that read calls in flight can finish (step 5). It runs once the
    /// executor is already stopping, alongside the executor's own stop.
    func stopAcceptingCalls() async

    /// Drops the lease and every frame, so nothing answered before the exit names them; the next
    /// start begins with neither (contract 12.9 step 3, 15.2).
    func dropLeaseAndFrames() async

    /// Step 4's log of the stop itself. Must not wait: it runs once the deadline has passed too.
    func logStop(_ report: CleanStopReport)

    /// Step 5: lets read calls in flight finish, then closes every connection.
    func closeConnections() async
}

/// What a process stop did, for its log entry.
public struct CleanStopReport: Hashable, Sendable {
    /// `nil` when the executor had not answered by the deadline: a call before admission was still
    /// waiting on the action log, a frame check or a patch recapture. Whatever reached the disk is
    /// what the next start recovers (contract 12.9).
    public let executor: ExecutorStop?
    /// Whether the stopped operation's outcome entry was committed to the action log. `nil` when
    /// the stop ended no operation, or its entries were not settled by the deadline.
    public let outcomeLogged: Bool?
    /// The lease and the frames were dropped before the deadline.
    public let leaseDropped: Bool
    /// From the signal to the log of the stop.
    public let elapsed: Duration

    public init(executor: ExecutorStop?, outcomeLogged: Bool?, leaseDropped: Bool, elapsed: Duration) {
        self.executor = executor
        self.outcomeLogged = outcomeLogged
        self.leaseDropped = leaseDropped
        self.elapsed = elapsed
    }
}

/// The process stop of contract 15.2, which `SIGTERM` starts: it marks the executor stopping, stops
/// taking calls, ends the operation in flight through ``StoppableExecutor/stop()``, drops the lease
/// and the frames, waits for the action log entries, logs the stop, lets read calls finish, and
/// exits with status 0.
///
/// Every wait races one deadline, ``margin`` short of `DEADLINE_BOUND_MS` after the signal, and the
/// exit follows it whatever is still waiting, so the process is gone within the bound. A step that
/// hangs costs only its own wait: the executor's stop does not wait for the listener, nor the drop
/// of the lease for the executor.
///
/// The stop runs once. A second ``stop(signalledAt:)``, as from a second `SIGTERM`, waits for the
/// first and changes nothing.
public actor CleanStop {
    public static let exitStatus: Int32 = 0
    /// What is kept back from the bound for the work after the deadline: the stop's log entry and
    /// the exit itself.
    public static let defaultMargin = Duration.milliseconds(150)

    private let executor: any StoppableExecutor
    private let host: any CleanStopHost
    private let scheduler: any WatchdogScheduler
    private let bound: Duration
    public let margin: Duration
    private let exit: @Sendable (Int32) -> Void
    private var running: Task<CleanStopReport, Never>?

    /// `exit` ends the process; in deskhand it does not return.
    public init(
        executor: any StoppableExecutor, host: any CleanStopHost,
        scheduler: any WatchdogScheduler = ContinuousClockScheduler(),
        bound: Duration = .milliseconds(ContractConstants.deadlineBoundMs), margin: Duration = defaultMargin,
        exit: @escaping @Sendable (Int32) -> Void
    ) {
        self.executor = executor
        self.host = host
        self.scheduler = scheduler
        self.bound = bound
        self.margin = margin
        self.exit = exit
    }

    /// Stops deskhand and exits. `signal` is when the signal arrived, on the scheduler's clock; the
    /// bound runs from it, and from now when it is `nil`. Returns the report it logged, only when
    /// `exit` returns, as a test's does.
    @discardableResult
    public func stop(signalledAt signal: ContinuousClock.Instant? = nil) async -> CleanStopReport {
        if let running { return await running.value }
        let (executor, host, scheduler, exit) = (self.executor, self.host, self.scheduler, self.exit)
        let start = signal ?? scheduler.now
        let deadline = start.advanced(by: bound - margin)
        let task = Task {
            // Before step 1: a host that closes connections must not turn the stopped effect into a
            // cancelled one.
            _ = await Self.within(deadline, on: scheduler) { await executor.beginStop() }
            let accepting = Task { await host.stopAcceptingCalls() }
            let ended = await Self.within(deadline, on: scheduler) { await executor.stop() }
            let dropped = await Self.within(deadline, on: scheduler) { await host.dropLeaseAndFrames() } != nil
            let entries = await Self.within(deadline, on: scheduler) { await executor.awaitStopEntries() }
            let report = CleanStopReport(
                executor: ended, outcomeLogged: entries ?? nil, leaseDropped: dropped,
                elapsed: start.duration(to: scheduler.now))
            host.logStop(report)
            // Past the deadline the exit closes what is still open.
            _ = await Self.within(deadline, on: scheduler) {
                await accepting.value
                await host.closeConnections()
            }
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
