#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// What `fstat` said about an opened directory or file.
public struct AllowanceFileStatus: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case regular
        case directory
        case other
    }

    public let kind: Kind
    public let owner: UInt32
    /// The low twelve mode bits.
    public let permissions: UInt32

    public init(kind: Kind, owner: UInt32, permissions: UInt32) {
        self.kind = kind
        self.owner = owner
        self.permissions = permissions & 0o7777
    }
}

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
        /// The permission deskhand's user needs on the allowance directory.
        static let directoryAccess = "search"
    #elseif canImport(Glibc)
        // `O_PATH`, which Swift's Glibc module exports only under its internal name.
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
        let directoryStatus: AllowanceFileStatus
        switch Self.status(of: directoryDescriptor) {
        case .success(let status): directoryStatus = status
        case .failure(let error): return .directoryFailed(error)
        }

        // O_NONBLOCK keeps a FIFO in the directory from blocking the open; it is refused below.
        let fileDescriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else { return .fileFailed(directory: directoryStatus, error: Self.openError(errno)) }
        defer { _ = close(fileDescriptor) }
        let fileStatus: AllowanceFileStatus
        switch Self.status(of: fileDescriptor) {
        case .success(let status): fileStatus = status
        case .failure(let error): return .fileFailed(directory: directoryStatus, error: error)
        }
        guard fileStatus.kind == .regular else {
            return .opened(directory: directoryStatus, file: fileStatus, contents: [])
        }
        switch Self.read(fileDescriptor, limit: maxBytes + 1) {
        case .success(let contents): return .opened(directory: directoryStatus, file: fileStatus, contents: contents)
        case .failure(let error): return .fileFailed(directory: directoryStatus, error: error)
        }
    }

    private static func openError(_ code: Int32) -> AllowanceOpenError {
        switch code {
        case ENOENT: .notFound
        case ELOOP: .symbolicLink
        default: .failed(errno: code)
        }
    }

    private static func status(of descriptor: Int32) -> Result<AllowanceFileStatus, AllowanceOpenError> {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return .failure(.failed(errno: errno)) }
        let mode = UInt32(status.st_mode)
        let kind: AllowanceFileStatus.Kind =
            switch mode & UInt32(S_IFMT) {
            case UInt32(S_IFREG): .regular
            case UInt32(S_IFDIR): .directory
            default: .other
            }
        return .success(AllowanceFileStatus(kind: kind, owner: UInt32(status.st_uid), permissions: mode))
    }

    private static func read(_ descriptor: Int32, limit: Int) -> Result<[UInt8], AllowanceOpenError> {
        var contents: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while contents.count < limit {
            let wanted = min(buffer.count, limit - contents.count)
            let count = buffer.withUnsafeMutableBytes { systemRead(descriptor, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.failed(errno: errno))
            }
            if count == 0 { break }
            contents += buffer[0..<count]
        }
        return .success(contents)
    }
}

/// `read(2)`, which ``POSIXAllowanceFileProbe`` hides behind its own `read`.
private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}

/// The log line for a directory that cannot be opened, naming the permission it needs when that
/// is the reason.
func allowanceDirectoryFailure(errno code: Int32) -> String {
    let base = "the allowance directory cannot be opened (errno \(code))"
    guard code == EACCES else { return base }
    return base + ": deskhand's user needs \(POSIXAllowanceFileProbe.directoryAccess) permission on it"
}
