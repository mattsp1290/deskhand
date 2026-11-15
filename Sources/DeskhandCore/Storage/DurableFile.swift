#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// One owner-only file that survives a crash and power loss (contract 12.1, 12.7): the operation
/// records and the held-input ledger both sit on it.
///
/// - The directory that holds the file must exist. Every call opens it with
///   `O_NOFOLLOW | O_DIRECTORY` and refuses it unless it is owned by `owner` and neither group nor
///   others can write it: whoever can write it can remove the file, and a missing file reads as
///   empty, which would make the ledger forget what is down and the records forget every
///   operation. The file is then opened, created and renamed relative to that descriptor, so the
///   file used is the one in the directory checked.
/// - Every open of the file is `O_NOFOLLOW`, and the opened file is refused unless it is a regular
///   file owned by `owner` with no permission beyond `0600`.
/// - ``replace(with:)`` writes `<name>.tmp`, created `0600`, flushes it, renames it over the file
///   and flushes the directory, so a crash leaves the old bytes or the new ones.
/// - ``openForAppending()`` gives a journal its ``Appender``.
///
/// A flush is ``StorageFlush/fullFlush(_:)`` (`F_FULLFSYNC` on Darwin), falling back to `fsync`
/// only when that fails with `ENOTSUP` or `EINVAL`, which mean the file system does not support it.
/// Any other flush error is thrown, because the bytes may not be on stable storage.
public struct DurableFile: Sendable {
    public let path: String
    /// The uid that must own the file and the directory that holds it.
    public let owner: UInt32
    public let flusher: any StorageFlush

    /// What `F_FULLFSYNC` fails with when the file system does not support it, as opposed to
    /// failing to flush.
    private static let fullFlushUnsupported: Set<Int32> = [ENOTSUP, EINVAL]

    /// The effective uid of this process: the owner every file is checked against by default.
    public static var currentUser: UInt32 { UInt32(geteuid()) }

    public init(path: String, owner: UInt32 = currentUser, flusher: any StorageFlush = SystemStorageFlush()) {
        self.path = path
        self.owner = owner
        self.flusher = flusher
    }

    /// The whole file, or `nil` when the directory holds none.
    public func read() throws(StorageError) -> [UInt8]? {
        let directory = try openDirectory()
        defer { _ = close(directory) }
        let descriptor = name.withCString { openat(directory, $0, O_RDONLY | Self.checkedOpen) }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw .io(operation: "open", errno: errno)
        }
        defer { _ = close(descriptor) }
        try verify(descriptor)
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { systemRead(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw .io(operation: "read", errno: errno)
            }
            if count == 0 { return bytes }
            bytes += buffer[0..<count]
        }
    }

    /// Makes `bytes` the file's contents, atomically and durably: once this returns they survive
    /// power loss, and a crash before then leaves the previous contents whole. When this throws
    /// after the rename, the new contents are in place but may not be durable.
    public func replace(with bytes: [UInt8]) throws(StorageError) {
        let directory = try openDirectory()
        defer { _ = close(directory) }
        let temporary = name + ".tmp"
        // A leftover from a crash may have any owner or mode; O_EXCL then guarantees a new file.
        if temporary.withCString({ unlinkat(directory, $0, 0) }) != 0, errno != ENOENT {
            throw .io(operation: "unlink", errno: errno)
        }
        let descriptor = temporary.withCString {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw .io(operation: "open", errno: errno) }
        do throws(StorageError) {
            // A strict umask can take away owner write, which every later append needs.
            guard fchmod(descriptor, 0o600) == 0 else { throw .io(operation: "fchmod", errno: errno) }
            try writeAll(bytes, to: descriptor)
            try flush(descriptor)
        } catch {
            _ = close(descriptor)
            throw error
        }
        _ = close(descriptor)
        guard renameat(directory, temporary, directory, name) == 0 else {
            throw .io(operation: "rename", errno: errno)
        }
        // Makes the rename itself durable.
        try flush(directory)
    }

    /// Opens the existing file for appending, checked as ``read()`` checks it.
    public func openForAppending() throws(StorageError) -> Appender {
        let directory = try openDirectory()
        defer { _ = close(directory) }
        let descriptor = name.withCString { openat(directory, $0, O_WRONLY | O_APPEND | Self.checkedOpen) }
        guard descriptor >= 0 else { throw .io(operation: "open", errno: errno) }
        do throws(StorageError) {
            try verify(descriptor)
        } catch {
            _ = close(descriptor)
            throw error
        }
        return Appender(descriptor: descriptor, file: self)
    }

    /// The end of a journal. One descriptor serves every append and flush, so a flush covers, and
    /// reports errors for, exactly the writes made through it. Closed when released.
    ///
    /// Not `Sendable`: owned by one journal.
    public final class Appender {
        private let descriptor: Int32
        private let file: DurableFile

        fileprivate init(descriptor: Int32, file: DurableFile) {
            self.descriptor = descriptor
            self.file = file
        }

        deinit { _ = close(descriptor) }

        /// Not durable until ``synchronize()`` returns.
        public func append(_ bytes: [UInt8]) throws(StorageError) {
            try writeAll(bytes, to: descriptor)
        }

        /// Flushes everything appended so far to stable storage.
        public func synchronize() throws(StorageError) {
            try file.flush(descriptor)
        }
    }

    /// Flags of every open that must land on the file itself. `O_NONBLOCK` keeps a FIFO planted at
    /// the path from blocking the open; the check then refuses it, and regular files ignore it.
    private static let checkedOpen = O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

    fileprivate func flush(_ descriptor: Int32) throws(StorageError) {
        do throws(StorageError) {
            try flusher.fullFlush(descriptor)
        } catch {
            guard case .io(_, let code) = error, Self.fullFlushUnsupported.contains(code) else { throw error }
            try flusher.flush(descriptor)
        }
    }

    /// The checked directory that holds the file. Read access lets it be flushed.
    private func openDirectory() throws(StorageError) -> Int32 {
        let descriptor = directoryPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw .io(operation: "open directory", errno: errno) }
        var status = stat()
        let problem: StorageError? =
            if fstat(descriptor, &status) != 0 {
                .io(operation: "fstat directory", errno: errno)
            } else if UInt32(status.st_uid) != owner {
                .directoryWrongOwner(owner: UInt32(status.st_uid), expected: owner)
            } else if UInt32(status.st_mode) & 0o022 != 0 {
                .directoryWritableByOthers(mode: UInt32(status.st_mode) & 0o7777)
            } else {
                nil
            }
        if let problem {
            _ = close(descriptor)
            throw problem
        }
        return descriptor
    }

    private var directoryPath: String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    private var name: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private func verify(_ descriptor: Int32) throws(StorageError) {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw .io(operation: "fstat", errno: errno) }
        let mode = UInt32(status.st_mode)
        guard mode & 0o170000 == 0o100000 else { throw .notRegularFile }
        guard UInt32(status.st_uid) == owner else { throw .wrongOwner(owner: UInt32(status.st_uid), expected: owner) }
        guard mode & 0o7777 & ~0o600 == 0 else { throw .permissionsTooWide(mode: mode & 0o7777) }
    }
}

private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws(StorageError) {
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw .io(operation: "write", errno: errno)
        }
        offset += count
    }
}

/// `read(2)`, which ``DurableFile/read()`` hides inside the type.
private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}
