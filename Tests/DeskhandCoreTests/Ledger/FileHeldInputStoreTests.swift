import DeskhandCore
import Foundation
import Testing

/// The ledger on a real ``DurableFile`` (A1): the same owner, mode, link and flush rules as the
/// operation records.
@Suite struct FileHeldInputStoreTests {
    @Test func replacesAtomicallyWithOwnerOnlyPermissions() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/held-input.json"
            let store = FileHeldInputStore(path: path)
            #expect(try store.load() == nil)
            try store.replace(with: Array("first".utf8))
            #expect(try store.load() == Array("first".utf8))
            #expect(try permissions(of: path) == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["held-input.json"])
        }
    }

    @Test func theLedgerRecoversFromTheFile() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/held-input.json"
            var ledger = try HeldInputLedger(store: FileHeldInputStore(path: path))
            try ledger.willPress(.command)
            try ledger.willPress(.button(.right))

            let recovered = try HeldInputLedger(store: FileHeldInputStore(path: path))
            let pending = recovered.pending()
            #expect(pending == [.command, .button(.right)])
        }
    }

    /// A missing directory is not an empty ledger: the ledger does not load, so no press is guarded
    /// by a file that cannot exist.
    @Test func aMissingDirectoryFailsTheLoad() throws {
        try withTemporaryDirectory { directory in
            try expectReadFailed(
                directory + "/absent/held-input.json", .io(operation: "open directory", errno: ENOENT))
        }
    }

    /// Re-reviews A3 and B4: whoever can write the directory could remove the ledger, which would
    /// then load empty with input still down.
    @Test func refusesALedgerInADirectoryOthersCanWrite() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/held-input.json"
            try FileHeldInputStore(path: path).replace(with: Array(#"{"held":[],"version":1}"#.utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory)
            try expectReadFailed(path, .directoryWritableByOthers(mode: 0o777))
        }
    }

    @Test func aDirectoryAtThePathFailsToOpen() throws {
        try withTemporaryDirectory { directory in
            #expect(throws: HeldInputLedgerError.self) {
                _ = try HeldInputLedger(store: FileHeldInputStore(path: directory))
            }
        }
    }

    /// A ledger others can write could be emptied, leaving input down with no `cleanup_pending`.
    @Test(arguments: [0o666, 0o644, 0o620])
    func refusesALedgerWithWiderPermissions(_ mode: Int) throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/held-input.json"
            try FileHeldInputStore(path: path).replace(with: Array(#"{"held":[],"version":1}"#.utf8))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
            try expectReadFailed(path, .permissionsTooWide(mode: UInt32(mode)))
        }
    }

    @Test func refusesALedgerBehindASymbolicLink() throws {
        try withTemporaryDirectory { directory in
            let target = directory + "/elsewhere.json"
            try FileHeldInputStore(path: target).replace(with: Array(#"{"held":[],"version":1}"#.utf8))
            let path = directory + "/held-input.json"
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
            try expectReadFailed(path, .io(operation: "open", errno: ELOOP))
        }
    }

    /// B3 through the ledger: a failed `F_FULLFSYNC` is a failed write, so the down is not posted.
    @Test func aFullFlushErrorFailsThePress() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/held-input.json"
            let flusher = ScriptedFlush.failing(.full, with: EIO)
            var ledger = try HeldInputLedger(store: FileHeldInputStore(path: path, flusher: flusher))
            do throws(HeldInputLedgerError) {
                try ledger.willPress(.keyA)
                Issue.record("willPress returned after F_FULLFSYNC failed")
            } catch {
                guard case .writeFailed(let cause) = error else {
                    Issue.record("\(error)")
                    return
                }
                #expect(cause as? StorageError == .io(operation: "F_FULLFSYNC", errno: EIO))
            }
            #expect(flusher.calls == [.full])
            let available = ledger.isAvailable
            #expect(!available)
            #expect(try FileHeldInputStore(path: path).load() == nil)
        }
    }

    /// A2 on a real file: the clear's rename lands and the directory flush then fails. The press
    /// that follows is refused until the ledger is reloaded from the file.
    @Test func aFailedDirectoryFlushAfterTheRenameMakesTheLedgerUnavailable() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/held-input.json"
            // Each write flushes the temporary file, then the directory: the clear's directory
            // flush is the fourth.
            let flusher = ScriptedFlush.failing(.full, with: EIO, at: 3)
            var ledger = try HeldInputLedger(store: FileHeldInputStore(path: path, flusher: flusher))
            let left = HeldInput.button(.left)
            try ledger.willPress(left)
            #expect(throws: HeldInputLedgerError.self) { try ledger.didRelease(left) }
            #expect(try HeldInputLedger(store: FileHeldInputStore(path: path)).pending().isEmpty)
            #expect(throws: HeldInputLedgerError.self) { try ledger.willPress(left) }

            try ledger.reload()
            try ledger.willPress(left)
            #expect(try HeldInputLedger(store: FileHeldInputStore(path: path)).pending() == [left])
        }
    }

    private func expectReadFailed(
        _ path: String, _ expected: StorageError, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        do {
            _ = try HeldInputLedger(store: FileHeldInputStore(path: path))
            Issue.record("opened \(path)", sourceLocation: sourceLocation)
        } catch {
            guard case .readFailed(let cause) = error else {
                Issue.record("\(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(cause as? StorageError == expected, sourceLocation: sourceLocation)
        }
    }
}
