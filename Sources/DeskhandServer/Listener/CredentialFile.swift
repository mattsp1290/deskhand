#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Why a credential file was refused. Carries modes and error numbers, never file content.
public enum CredentialFileError: Error, Hashable, Sendable, CustomStringConvertible {
    case missing
    /// A symbolic link, directory, device or anything else that is not a regular file.
    case notRegularFile
    case notOwnedByUser(owner: UInt32)
    /// Group or other has any permission bit; `mode` is the low 12 bits.
    case accessibleByOthers(mode: UInt32)
    case tooLarge(byteCount: Int)
    case unreadable(errno: Int32)

    public var description: String {
        switch self {
        case .missing: "file does not exist"
        case .notRegularFile: "not a regular file (symbolic links are refused)"
        case .notOwnedByUser(let owner): "owned by uid \(owner), not by this process's user"
        case .accessibleByOthers(let mode): "mode \(String(mode, radix: 8)) grants group or other access; use 0600"
        case .tooLarge(let count): "\(count) bytes is larger than a credential file can be"
        case .unreadable(let code): "cannot be read (errno \(code))"
        }
    }
}

/// Reads the private CA, the server certificate, the server key and the token. Each must be a
/// regular file owned by this process's effective user with no group or other permission bits
/// (0600 or 0400). The CA is held to the same rule as the key because a writable trust anchor
/// would let anyone mint a client certificate.
public enum CredentialFile {
    public static let maxByteCount = 1 << 20

    /// The file is opened without blocking: opening a FIFO with no writer would otherwise wait
    /// forever, stalling startup or every later reload, before the regular-file check could refuse
    /// it. A regular file reads the same either way.
    public static func read(path: String) throws(CredentialFileError) -> [UInt8] {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw .missing
            case ELOOP: throw .notRegularFile
            case let code: throw .unreadable(errno: code)
            }
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(errno: errno) }
        let mode = UInt32(info.st_mode)
        guard mode & 0o170000 == 0o100000 else { throw .notRegularFile }
        guard info.st_uid == geteuid() else { throw .notOwnedByUser(owner: UInt32(info.st_uid)) }
        guard mode & 0o077 == 0 else { throw .accessibleByOthers(mode: mode & 0o7777) }
        guard Int(info.st_size) <= maxByteCount else { throw .tooLarge(byteCount: Int(info.st_size)) }

        var contents: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = chunk.withUnsafeMutableBytes { Syscall.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable(errno: errno)
            }
            contents += chunk[..<count]
            guard contents.count <= maxByteCount else { throw .tooLarge(byteCount: contents.count) }
        }
        return contents
    }
}

/// `read` is shadowed inside ``CredentialFile`` by its own static method.
private enum Syscall {
    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.read(descriptor, buffer, count)
        #else
            Glibc.read(descriptor, buffer, count)
        #endif
    }
}
