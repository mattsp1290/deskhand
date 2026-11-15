import Synchronization

/// The operation records' file (contract 12.1) as the executor loads it: at start, and again after
/// a failed write left the store unavailable. Each load opens the file afresh.
public struct FileOperationStoreLoader: OperationStoreLoader {
    public let path: String
    public let configuration: OperationStore.Configuration
    /// The uid that must own the file and its directory.
    public let owner: UInt32
    public let flusher: any StorageFlush

    public init(
        path: String, configuration: OperationStore.Configuration = .init(), owner: UInt32 = DurableFile.currentUser,
        flusher: any StorageFlush = SystemStorageFlush()
    ) {
        self.path = path
        self.configuration = configuration
        self.owner = owner
        self.flusher = flusher
    }

    public func load(now: Timestamp) throws(OperationStoreLoadError) -> OperationStore {
        try OperationStore(
            storage: FileOperationStorage(path: path, owner: owner, flusher: flusher), configuration: configuration,
            now: now)
    }
}

final class StartLoadRecorder: OperationStoreLoader {
    private let loader: any OperationStoreLoader
    private let first = Mutex<OperationRecordsRecovery?>(nil)

    init(_ loader: any OperationStoreLoader) { self.loader = loader }

    var firstLoad: OperationRecordsRecovery? { first.withLock { $0 } }

    func load(now: Timestamp) throws(OperationStoreLoadError) -> OperationStore {
        do throws(OperationStoreLoadError) {
            let store = try loader.load(now: now)
            keep(.loaded(restarted: store.restartedAtLoad))
            return store
        } catch {
            keep(.unavailable(error))
            throw error
        }
    }

    private func keep(_ recovery: OperationRecordsRecovery) {
        first.withLock { first in
            if first == nil { first = recovery }
        }
    }
}
