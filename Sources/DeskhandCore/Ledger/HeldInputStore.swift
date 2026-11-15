/// Where the held-input ledger's bytes live. `replace` is the only write, so a crash at any moment
/// leaves either the previous bytes or the new ones.
public protocol HeldInputStore {
    /// The bytes of the last `replace` that reached storage, or `nil` if there never was one.
    func load() throws -> [UInt8]?
    /// Makes `bytes` the stored contents, atomically and durably: once it returns they survive a
    /// crash, and a crash before then leaves the previous contents whole. When it throws, either
    /// may be stored.
    func replace(with bytes: [UInt8]) throws
}

/// The ledger as a ``DurableFile``: owner-only, replaced whole on every write.
public struct FileHeldInputStore: HeldInputStore, Sendable {
    public let file: DurableFile

    public init(
        path: String, owner: UInt32 = DurableFile.currentUser, flusher: any StorageFlush = SystemStorageFlush()
    ) {
        file = DurableFile(path: path, owner: owner, flusher: flusher)
    }

    public func load() throws -> [UInt8]? { try file.read() }

    public func replace(with bytes: [UInt8]) throws { try file.replace(with: bytes) }
}
