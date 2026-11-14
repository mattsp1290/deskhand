import DeskhandCore
import Foundation
import Testing

@Suite struct FileHeldInputStoreTests {
    /// A fresh directory, removed after `body`.
    private func withDirectory(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskhand-ledger-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try body(directory)
    }

    private func permissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    @Test func replacesAtomicallyWithOwnerOnlyPermissions() throws {
        try withDirectory { directory in
            let path = directory + "/held-input.json"
            let store = FileHeldInputStore(path: path)
            #expect(try store.load() == nil)

            try store.replace(with: Array("first".utf8))
            #expect(try store.load() == Array("first".utf8))
            try store.replace(with: Array("second, longer".utf8))
            #expect(try store.load() == Array("second, longer".utf8))
            try store.replace(with: [])
            #expect(try store.load() == [])

            #expect(try permissions(path) == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["held-input.json"])
        }
    }

    @Test func aLeftoverTemporaryFileDoesNotWidenPermissions() throws {
        try withDirectory { directory in
            let path = directory + "/held-input.json"
            #expect(
                FileManager.default.createFile(
                    atPath: path + ".tmp", contents: Data("stale".utf8), attributes: [.posixPermissions: 0o644]))
            try FileHeldInputStore(path: path).replace(with: Array("fresh".utf8))
            #expect(try permissions(path) == 0o600)
            #expect(try FileHeldInputStore(path: path).load() == Array("fresh".utf8))
        }
    }

    @Test func theLedgerRecoversFromTheFile() throws {
        try withDirectory { directory in
            let path = directory + "/held-input.json"
            var ledger = try HeldInputLedger(store: FileHeldInputStore(path: path))
            try ledger.willPress(.modifier(.command))
            try ledger.willPress(.button(.right))

            let recovered = try HeldInputLedger(store: FileHeldInputStore(path: path))
            let pending = recovered.pending()
            #expect(pending == [.modifier(.command), .button(.right)])
        }
    }

    @Test func aMissingDirectoryFailsTheWriteThatGuardsAPress() throws {
        try withDirectory { directory in
            var ledger = try HeldInputLedger(store: FileHeldInputStore(path: directory + "/absent/held-input.json"))
            do {
                try ledger.willPress(.key(.a))
                Issue.record("willPress returned without a ledger file")
            } catch {
                guard case .writeFailed(let cause)? = error as? HeldInputLedgerError else {
                    Issue.record("\(error)")
                    return
                }
                #expect((cause as? FileHeldInputStoreError)?.operation == "open")
            }
            let pending = ledger.pending()
            #expect(pending.isEmpty)
        }
    }

    @Test func anUnreadableLedgerFailsToOpen() throws {
        try withDirectory { directory in
            #expect(throws: HeldInputLedgerError.self) {
                _ = try HeldInputLedger(store: FileHeldInputStore(path: directory))
            }
        }
    }
}
