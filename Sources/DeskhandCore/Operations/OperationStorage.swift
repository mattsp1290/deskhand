/// The bytes behind an ``OperationStore``: one journal file that only its owner can read or write
/// (contract 12.1). Each method is one write boundary, which is what fault-injection tests cut at.
///
/// A class protocol because a storage is a handle on state outside the process: two stores built
/// on the same storage see the same file, the way a restarted deskhand does.
public protocol OperationStorage: AnyObject {
    /// The whole journal, or `nil` when there is none yet. Refuses a file that is not a regular
    /// file, is owned by someone else, or grants anything beyond owner read and write.
    func read() throws(OperationStorageError) -> [UInt8]?

    /// Appends to the journal. Not durable until ``synchronize()`` returns.
    func append(_ bytes: [UInt8]) throws(OperationStorageError)

    /// Flushes everything appended so far to stable storage.
    func synchronize() throws(OperationStorageError)

    /// Replaces the whole journal with `bytes`, atomically and durably: afterwards the file holds
    /// either the old bytes or the new ones, never a mix, and once this returns the new ones
    /// survive power loss. The new file is owner-only.
    func replace(with bytes: [UInt8]) throws(OperationStorageError)
}

public enum OperationStorageError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file's permission bits include more than `0600`.
    case permissionsTooWide(mode: UInt32)
    case wrongOwner(owner: UInt32, expected: UInt32)
    case notRegularFile
    /// A system call failed. `operation` names it for the log.
    case io(operation: String, errno: Int32)

    public var description: String {
        switch self {
        case .permissionsTooWide(let mode): "operation record file mode is 0\(String(mode, radix: 8)), not 0600"
        case .wrongOwner(let owner, let expected):
            "operation record file is owned by uid \(owner), not \(expected)"
        case .notRegularFile: "operation record path is not a regular file"
        case .io(let operation, let errno): "\(operation) failed with errno \(errno)"
        }
    }
}

/// Why ``OperationStore`` could not start. deskhand then refuses every effect call with
/// `internal_error` (contract 12.3) rather than run without its records.
public enum OperationStoreLoadError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file could not be read, or is not owner-only.
    case unreadable(OperationStorageError)
    /// A line other than a torn last one does not decode, or describes a transition the
    /// lifecycle does not allow. `line` counts from 1.
    case corrupt(line: Int, reason: String)
    /// The restart rules could not be written back durably (contract 12.9).
    case notWritable(OperationStorageError)

    public var description: String {
        switch self {
        case .unreadable(let error): "cannot read operation records: \(error)"
        case .corrupt(let line, let reason): "operation record file line \(line): \(reason)"
        case .notWritable(let error): "cannot write operation records: \(error)"
        }
    }
}

/// Why a store call was refused. Every refusal leaves the store's records as they were.
public enum OperationStoreError: Error, Hashable, Sendable {
    /// An earlier write failed, so the file may end in a partial entry. Nothing more is written
    /// until a new store is loaded from the storage; until then every effect call is refused with
    /// `internal_error` (contract 12.3).
    case unavailable
    /// This write failed. The store is ``unavailable`` from now on.
    case writeFailed(OperationStorageError)
    /// The ticket's record does not exist: it was never admitted here, or a reload replaced it.
    case unknownOperation(OperationKey)
    /// The lifecycle does not allow this change from `from` (contract 12.2).
    case illegalTransition(OperationKey, from: OperationStatus)
    /// The result holds a number JSON cannot spell, so it cannot be stored.
    case unencodableResult(OperationKey)
}
