/// The operation journal as one ``DurableFile`` (contract 12.1): owner-only, appended through one
/// open descriptor, and replaced whole at load and compaction.
///
/// Not `Sendable`; owned by one ``OperationStore``.
public final class FileOperationStorage: OperationStorage {
    public let file: DurableFile
    private var appender: DurableFile.Appender?

    public init(
        path: String, owner: UInt32 = DurableFile.currentUser, flusher: any StorageFlush = SystemStorageFlush()
    ) {
        file = DurableFile(path: path, owner: owner, flusher: flusher)
    }

    public var path: String { file.path }

    public func read() throws(StorageError) -> [UInt8]? {
        try file.read()
    }

    public func append(_ bytes: [UInt8]) throws(StorageError) {
        if appender == nil { appender = try file.openForAppending() }
        try appender?.append(bytes)
    }

    public func synchronize() throws(StorageError) {
        try appender?.synchronize()
    }

    public func replace(with bytes: [UInt8]) throws(StorageError) {
        appender = nil
        try file.replace(with: bytes)
    }
}
