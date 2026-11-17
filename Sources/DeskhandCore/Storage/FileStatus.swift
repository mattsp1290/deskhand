#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// What `fstat` said about an opened directory or file. The allowance check and ``DurableFile``
/// judge the same facts, each against its own owner, so both take them from here.
public struct FileStatus: Hashable, Sendable {
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

    /// Group or others may write it. Whoever can write a directory can replace what it holds.
    public var isWritableByGroupOrOthers: Bool { permissions & 0o022 != 0 }

    /// `fstat` of `descriptor`.
    static func of(_ descriptor: Int32) throws(SystemCallError) -> FileStatus {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw SystemCallError(errno: errno) }
        let mode = UInt32(status.st_mode)
        let kind: Kind =
            switch mode & UInt32(S_IFMT) {
            case UInt32(S_IFREG): .regular
            case UInt32(S_IFDIR): .directory
            default: .other
            }
        return FileStatus(kind: kind, owner: UInt32(status.st_uid), permissions: mode)
    }
}

/// A system call failed with `errno`, read where it failed.
struct SystemCallError: Error, Hashable {
    let errno: Int32
}

/// Up to `limit` bytes from `descriptor`, fewer at end of file.
func readContents(of descriptor: Int32, limit: Int = .max) throws(SystemCallError) -> [UInt8] {
    var contents: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: max(0, min(limit, 65_536)))
    while contents.count < limit {
        let wanted = min(buffer.count, limit - contents.count)
        var failure: Int32 = 0
        let count = buffer.withUnsafeMutableBytes { bytes in
            let count = systemRead(descriptor, bytes.baseAddress, wanted)
            if count < 0 { failure = errno }
            return count
        }
        if count < 0 {
            if failure == EINTR { continue }
            throw SystemCallError(errno: failure)
        }
        if count == 0 { break }
        contents += buffer[0..<count]
    }
    return contents
}

/// The directory that holds `path`, and the last component, which is opened relative to it.
func splitPath(_ path: String) -> (directory: String, name: String) {
    guard let slash = path.lastIndex(of: "/") else { return (".", path) }
    let directory = slash == path.startIndex ? "/" : String(path[..<slash])
    return (directory, String(path[path.index(after: slash)...]))
}

private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}
