#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The operation journal as one owner-only file (contract 12.1).
///
/// The file is created `0600` and refused when it is anything but a regular file owned by
/// `owner` with no permission beyond `0600`. Replacing it writes `<path>.tmp`, flushes it, renames
/// it over the file and flushes the directory, so a crash leaves the old file or the new one.
///
/// Not `Sendable`; owned by one ``OperationStore``.
public final class FileOperationStorage: OperationStorage {
    public let path: String
    /// The uid that must own the file.
    public let owner: UInt32
    private var appendDescriptor: Int32?

    public init(path: String, owner: UInt32 = UInt32(geteuid())) {
        self.path = path
        self.owner = owner
    }

    deinit {
        if let appendDescriptor { _ = close(appendDescriptor) }
    }

    public func read() throws(OperationStorageError) -> [UInt8]? {
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
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

    public func append(_ bytes: [UInt8]) throws(OperationStorageError) {
        let descriptor: Int32
        if let appendDescriptor {
            descriptor = appendDescriptor
        } else {
            descriptor = path.withCString { open($0, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else { throw .io(operation: "open", errno: errno) }
            do throws(OperationStorageError) {
                try verify(descriptor)
            } catch {
                _ = close(descriptor)
                throw error
            }
            appendDescriptor = descriptor
        }
        try writeAll(bytes, to: descriptor)
    }

    public func synchronize() throws(OperationStorageError) {
        guard let appendDescriptor else { return }
        try flush(appendDescriptor)
    }

    public func replace(with bytes: [UInt8]) throws(OperationStorageError) {
        let temporary = path + ".tmp"
        if temporary.withCString({ unlink($0) }) != 0, errno != ENOENT {
            throw .io(operation: "unlink", errno: errno)
        }
        let descriptor = temporary.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw .io(operation: "open", errno: errno) }
        do throws(OperationStorageError) {
            // A strict umask can take away owner write, which every later append needs.
            guard fchmod(descriptor, 0o600) == 0 else { throw .io(operation: "fchmod", errno: errno) }
            try writeAll(bytes, to: descriptor)
            try flush(descriptor)
        } catch {
            _ = close(descriptor)
            throw error
        }
        _ = close(descriptor)
        if let appendDescriptor {
            _ = close(appendDescriptor)
            self.appendDescriptor = nil
        }
        guard rename(temporary, path) == 0 else { throw .io(operation: "rename", errno: errno) }
        try flushDirectory()
    }

    private func flushDirectory() throws(OperationStorageError) {
        let descriptor = Self.directory(of: path).withCString { open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw .io(operation: "open directory", errno: errno) }
        defer { _ = close(descriptor) }
        try flush(descriptor)
    }

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    private func verify(_ descriptor: Int32) throws(OperationStorageError) {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw .io(operation: "fstat", errno: errno) }
        let mode = UInt32(status.st_mode)
        guard mode & 0o170000 == 0o100000 else { throw .notRegularFile }
        guard UInt32(status.st_uid) == owner else { throw .wrongOwner(owner: UInt32(status.st_uid), expected: owner) }
        guard mode & 0o7777 & ~0o600 == 0 else { throw .permissionsTooWide(mode: mode & 0o7777) }
    }

    private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws(OperationStorageError) {
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

    private func flush(_ descriptor: Int32) throws(OperationStorageError) {
        #if canImport(Darwin)
            // fsync on Darwin leaves data in the drive's cache; only F_FULLFSYNC reaches stable
            // storage. Some file systems do not support it, and fsync is the best they offer.
            if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        #endif
        while fsync(descriptor) != 0 {
            if errno != EINTR { throw .io(operation: "fsync", errno: errno) }
        }
    }
}

/// `read(2)`, which the storage's own `read()` hides inside the class.
private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
        Darwin.read(descriptor, buffer, count)
    #else
        Glibc.read(descriptor, buffer, count)
    #endif
}
