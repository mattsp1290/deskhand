/// Why a ``DurableFile`` call failed.
public enum StorageError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file's permission bits include more than `0600`.
    case permissionsTooWide(mode: UInt32)
    case wrongOwner(owner: UInt32, expected: UInt32)
    case notRegularFile
    /// The directory that holds the file is owned by another uid.
    case directoryWrongOwner(owner: UInt32, expected: UInt32)
    /// Group or others can write the directory that holds the file, so they could remove it.
    case directoryWritableByOthers(mode: UInt32)
    /// A system call failed. `operation` names it for the log.
    case io(operation: String, errno: Int32)

    public var description: String {
        switch self {
        case .permissionsTooWide(let mode): "file mode is 0\(String(mode, radix: 8)), not 0600"
        case .wrongOwner(let owner, let expected): "file is owned by uid \(owner), not \(expected)"
        case .notRegularFile: "path is not a regular file"
        case .directoryWrongOwner(let owner, let expected): "directory is owned by uid \(owner), not \(expected)"
        case .directoryWritableByOthers(let mode):
            "directory mode is 0\(String(mode, radix: 8)): group or others can write it"
        case .io(let operation, let errno): "\(operation) failed with errno \(errno)"
        }
    }
}
