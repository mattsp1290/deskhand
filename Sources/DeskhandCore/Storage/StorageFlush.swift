#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The flushes under a ``DurableFile``: the calls whose failure means written bytes may not survive
/// power loss. Tests substitute one to fail a chosen flush.
public protocol StorageFlush: Sendable {
    /// Flushes the file through the drive's write cache: `fcntl(F_FULLFSYNC)` on Darwin, where
    /// `fsync` leaves data in that cache, and `fsync` elsewhere, where it already reaches it.
    func fullFlush(_ descriptor: Int32) throws(StorageError)

    /// `fsync`. On Darwin, the fallback for a file system that does not support `F_FULLFSYNC`.
    func flush(_ descriptor: Int32) throws(StorageError)
}

/// The real system calls.
public struct SystemStorageFlush: StorageFlush {
    public init() {}

    public func fullFlush(_ descriptor: Int32) throws(StorageError) {
        #if canImport(Darwin)
            try retryingInterrupts("F_FULLFSYNC") { fcntl(descriptor, F_FULLFSYNC) }
        #else
            try retryingInterrupts("fsync") { fsync(descriptor) }
        #endif
    }

    public func flush(_ descriptor: Int32) throws(StorageError) {
        try retryingInterrupts("fsync") { fsync(descriptor) }
    }
}

private func retryingInterrupts(_ operation: String, _ call: () -> Int32) throws(StorageError) {
    while call() != 0 {
        guard errno == EINTR else { throw .io(operation: operation, errno: errno) }
    }
}
