#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

public typealias AllowanceFileStatus = FileStatus

/// Why `open` or `openat` failed.
public enum AllowanceOpenError: Error, Hashable, Sendable {
    case notFound
    /// The last path component is a symbolic link, refused by `O_NOFOLLOW`.
    case symbolicLink
    case failed(errno: Int32)
}

/// One look at the allowance directory and file, as raw facts. The reader decides what they mean.
public enum AllowanceProbe: Hashable, Sendable {
    case directoryFailed(AllowanceOpenError)
    case fileFailed(directory: AllowanceFileStatus, error: AllowanceOpenError)
    /// `contents` is read only from a regular file, and holds at most `maxBytes + 1` bytes so that
    /// an oversized file shows as one.
    case opened(directory: AllowanceFileStatus, file: AllowanceFileStatus, contents: [UInt8])
}

/// The system calls behind the allowance check, so tests can supply owners and modes that only
/// root could create.
public protocol AllowanceFileProbe: Sendable {
    func probe(directory: String, name: String, maxBytes: Int) -> AllowanceProbe
}

/// Opens the directory with `O_NOFOLLOW | O_DIRECTORY`, the file with `openat` and `O_NOFOLLOW`
/// relative to it, and `fstat`s each descriptor, so every check is of the object opened and
/// nothing is looked up by path twice (D15).
///
/// Reading a file by name needs only search permission on its directory, and contract 14.1 asks
/// the publisher for nothing more, so the directory is opened for search where the platform can:
/// a root-owned `0711` directory works. Elsewhere it is opened for reading, and a directory that
/// deskhand's user cannot read fails with a log line that says so.
public struct POSIXAllowanceFileProbe: AllowanceFileProbe {
    public init() {}

    #if canImport(Darwin)
        /// `O_SEARCH` includes `O_DIRECTORY`.
        private static let directoryOpen = O_SEARCH | O_NOFOLLOW | O_CLOEXEC
        static let directoryAccess = "search"
    #elseif canImport(Glibc)
        private static let directoryOpen = __O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        static let directoryAccess = "search"
    #else
        private static let directoryOpen = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        static let directoryAccess = "read and search"
    #endif

    public func probe(directory: String, name: String, maxBytes: Int) -> AllowanceProbe {
        let directoryDescriptor = directory.withCString { open($0, Self.directoryOpen) }
        guard directoryDescriptor >= 0 else { return .directoryFailed(Self.openError(errno)) }
        defer { _ = close(directoryDescriptor) }
        let directoryStatus: FileStatus
        do throws(SystemCallError) {
            directoryStatus = try FileStatus.of(directoryDescriptor)
        } catch {
            return .directoryFailed(.failed(errno: error.errno))
        }

        // O_NONBLOCK keeps a FIFO in the directory from blocking the open; it is refused below.
        let fileDescriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else { return .fileFailed(directory: directoryStatus, error: Self.openError(errno)) }
        defer { _ = close(fileDescriptor) }
        do throws(SystemCallError) {
            let fileStatus = try FileStatus.of(fileDescriptor)
            guard fileStatus.kind == .regular else {
                return .opened(directory: directoryStatus, file: fileStatus, contents: [])
            }
            let contents = try readContents(of: fileDescriptor, limit: maxBytes + 1)
            return .opened(directory: directoryStatus, file: fileStatus, contents: contents)
        } catch {
            return .fileFailed(directory: directoryStatus, error: .failed(errno: error.errno))
        }
    }

    private static func openError(_ code: Int32) -> AllowanceOpenError {
        switch code {
        case ENOENT: .notFound
        case ELOOP: .symbolicLink
        default: .failed(errno: code)
        }
    }
}

func allowanceDirectoryFailure(errno code: Int32) -> String {
    let base = "the allowance directory cannot be opened (errno \(code))"
    guard code == EACCES else { return base }
    return base + ": deskhand's user needs \(POSIXAllowanceFileProbe.directoryAccess) permission on it"
}
