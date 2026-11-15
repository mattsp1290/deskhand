import DeskhandCore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct FileHeldInputStoreTests {
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

    @Test func aMissingDirectoryFailsTheLoad() throws {
        try withTemporaryDirectory { directory in
            try expectReadFailed(
                directory + "/absent/held-input.json", .io(operation: "open directory", errno: ENOENT))
        }
    }

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

    @Test func aFailedDirectoryFlushAfterTheRenameMakesTheLedgerUnavailable() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/held-input.json"
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
