import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Where the held-input ledger's bytes live. `replace` is the only write, so a crash at any moment
/// leaves either the previous bytes or the new ones.
public protocol HeldInputStore {
    /// The bytes of the last `replace` that returned, or `nil` if there never was one.
    func load() throws -> [UInt8]?
    /// Makes `bytes` the stored contents, atomically and durably: once it returns they survive a
    /// crash, and a crash before then leaves the previous contents whole.
    func replace(with bytes: [UInt8]) throws
}

public struct FileHeldInputStoreError: Error, Hashable, Sendable, CustomStringConvertible {
    public let operation: String
    public let path: String
    public let code: Int32

    public var description: String { "\(operation) \(path): \(String(cString: strerror(code)))" }
}

/// The ledger as a file, owner-only (0600). A write goes to a sibling `.tmp` file, which is
/// flushed and renamed over the ledger, and then the directory is flushed. The directory must
/// already exist.
public struct FileHeldInputStore: HeldInputStore, Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    public func load() throws -> [UInt8]? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw FileHeldInputStoreError(operation: "open", path: path, code: errno)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return [UInt8](try handle.readToEnd() ?? Data())
    }

    public func replace(with bytes: [UInt8]) throws {
        let temporary = path + ".tmp"
        // A leftover from a crash may have other permissions; O_EXCL then guarantees the 0600 below.
        guard unlink(temporary) == 0 || errno == ENOENT else {
            throw FileHeldInputStoreError(operation: "unlink", path: temporary, code: errno)
        }
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FileHeldInputStoreError(operation: "open", path: temporary, code: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(bytes))
        try handle.synchronize()
        try handle.close()
        guard rename(temporary, path) == 0 else {
            throw FileHeldInputStoreError(operation: "rename", path: path, code: errno)
        }
        try synchronizeDirectory()
    }

    /// Makes the rename itself durable.
    private func synchronizeDirectory() throws {
        let directory: String
        if let slash = path.lastIndex(of: "/") {
            directory = slash == path.startIndex ? "/" : String(path[..<slash])
        } else {
            directory = "."
        }
        let descriptor = open(directory, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileHeldInputStoreError(operation: "open", path: directory, code: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.synchronize()
        try handle.close()
    }
}
