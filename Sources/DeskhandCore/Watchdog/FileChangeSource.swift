#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Tells the watchdog that the allowance file may have changed (contract 13.1, 14.4). The platform
/// implements a file watch; ``PollingFileChangeSource`` is the portable poll that backs it up.
public protocol FileChangeSource: Sendable {
    /// One element for each change noticed. Iteration ends when the iterating task is cancelled.
    func changes() -> AsyncStream<Void>
}

/// What `lstat` says about a path, compared between polls: a rewrite, a rename into place, a
/// removal, or a change of owner or mode all change it. `nil` stands for a path that cannot be
/// stat-ed, so appearing and disappearing are changes too.
public struct PathSignature: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let owner: UInt32
    public let size: Int64
    public let modified: Int64
    public let modifiedNanoseconds: Int64
    public let changed: Int64
    public let changedNanoseconds: Int64

    public init(
        device: UInt64, inode: UInt64, mode: UInt32, owner: UInt32, size: Int64, modified: Int64,
        modifiedNanoseconds: Int64, changed: Int64, changedNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.owner = owner
        self.size = size
        self.modified = modified
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changed = changed
        self.changedNanoseconds = changedNanoseconds
    }

    public static func of(path: String) -> PathSignature? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
            let modified = info.st_mtimespec
            let changed = info.st_ctimespec
        #else
            let modified = info.st_mtim
            let changed = info.st_ctim
        #endif
        return PathSignature(
            device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(truncatingIfNeeded: info.st_ino),
            mode: UInt32(truncatingIfNeeded: info.st_mode), owner: UInt32(truncatingIfNeeded: info.st_uid),
            size: Int64(truncatingIfNeeded: info.st_size), modified: Int64(truncatingIfNeeded: modified.tv_sec),
            modifiedNanoseconds: Int64(truncatingIfNeeded: modified.tv_nsec),
            changed: Int64(truncatingIfNeeded: changed.tv_sec),
            changedNanoseconds: Int64(truncatingIfNeeded: changed.tv_nsec))
    }
}

/// Polls the `lstat` signatures of the allowance file and its directory, and reports a change when
/// any differs from the previous poll. It works the same on macOS and Linux, and it notices what
/// a watch bound to one inode loses, such as a directory renamed into place.
public struct PollingFileChangeSource: FileChangeSource {
    /// Half of `DEADLINE_BOUND_MS`: a revocation that only the poll notices leaves the other half to
    /// cancel the effect, release its input and drop the lease (contract 13.1, 14.4).
    public static let defaultInterval: Duration = .milliseconds(ContractConstants.deadlineBoundMs / 2)

    public let paths: [String]
    public let interval: Duration
    private let scheduler: any WatchdogScheduler
    private let signature: @Sendable (String) -> PathSignature?

    /// `signature` reads one path; tests replace `lstat`.
    public init(
        paths: [String], interval: Duration = PollingFileChangeSource.defaultInterval,
        scheduler: any WatchdogScheduler = ContinuousClockScheduler(),
        signature: @escaping @Sendable (String) -> PathSignature? = PathSignature.of(path:)
    ) {
        self.paths = paths
        self.interval = interval
        self.scheduler = scheduler
        self.signature = signature
    }

    /// Watches the file `reader` reads and the directory that holds it.
    public init(
        allowance reader: AllowanceReader, interval: Duration = PollingFileChangeSource.defaultInterval,
        scheduler: any WatchdogScheduler = ContinuousClockScheduler()
    ) {
        self.init(
            paths: [AllowanceReader.split(reader.path).directory, reader.path], interval: interval,
            scheduler: scheduler)
    }

    /// The first poll is one ``interval`` after the call. Polls that fell behind are not made up in
    /// a burst: the next one runs at once.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task { [paths, interval, scheduler, signature] in
            var last = paths.map(signature)
            var next = scheduler.now
            while !Task.isCancelled {
                next = max(next.advanced(by: interval), scheduler.now)
                await scheduler.sleep(until: next)
                guard !Task.isCancelled else { break }
                let current = paths.map(signature)
                if current != last {
                    last = current
                    continuation.yield()
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
