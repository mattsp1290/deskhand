import DeskhandCore
import Foundation
import Testing

@Suite struct FileOperationStorageTests {
    /// A fresh directory per test; removed when the test's closure returns.
    static func withDirectory(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskhand-operations-\(UInt64.random(in: 0...UInt64.max))").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try body(directory)
    }

    static func mode(of path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    @Test func createsAnOwnerOnlyFile() throws {
        try Self.withDirectory { directory in
            let path = directory + "/operations.jsonl"
            let store = try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            #expect(try Self.mode(of: path) == 0o600)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
            #expect(!FileManager.default.fileExists(atPath: path + ".tmp"))

            let ticket = try Sample.admit(store, Sample.key("op-1"))
            try store.markExecuting(ticket)
            #expect(try Self.mode(of: path) == 0o600)
        }
    }

    @Test(arguments: [0o644, 0o640, 0o604, 0o700, 0o4600, 0o666])
    func refusesAFileWithWiderPermissions(_ mode: Int) throws {
        try Self.withDirectory { directory in
            let path = directory + "/operations.jsonl"
            _ = try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
            #expect(throws: OperationStoreLoadError.unreadable(.permissionsTooWide(mode: UInt32(mode)))) {
                try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            }
        }
    }

    @Test func acceptsANarrowerFileThatItCanStillRead() throws {
        try Self.withDirectory { directory in
            let path = directory + "/operations.jsonl"
            _ = try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path)
            _ = try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            #expect(try Self.mode(of: path) == 0o600, "the rewrite restores 0600")
        }
    }

    @Test func refusesAFileOwnedBySomeoneElse() throws {
        try Self.withDirectory { directory in
            let path = directory + "/operations.jsonl"
            _ = try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            let stranger = UInt32(geteuid()) &+ 1
            #expect(
                throws: OperationStoreLoadError.unreadable(.wrongOwner(owner: UInt32(geteuid()), expected: stranger))
            ) {
                try OperationStore(storage: FileOperationStorage(path: path, owner: stranger), now: Sample.start)
            }
        }
    }

    @Test func refusesASymbolicLink() throws {
        try Self.withDirectory { directory in
            let target = directory + "/elsewhere.jsonl"
            _ = try OperationStore(storage: FileOperationStorage(path: target), now: Sample.start)
            let path = directory + "/operations.jsonl"
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
            let error = #expect(throws: OperationStoreLoadError.self) {
                try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            }
            guard case .unreadable = error else { throw TestFailure("not unreadable: \(String(describing: error))") }
        }
    }

    /// B3: a failed `F_FULLFSYNC` on the `accepted` entry is a failed write. It is not hidden by an
    /// `fsync` that succeeds, and the store latches unavailable.
    @Test(arguments: [EIO, ENOSPC])
    func aFullFlushErrorMakesTheStoreUnavailable(_ code: Int32) throws {
        try Self.withDirectory { directory in
            let path = directory + "/operations.jsonl"
            // The load's rewrite makes two flushes; the admission's append makes the third.
            let flusher = ScriptedFlush.failing(.full, with: code, at: 2)
            let store = try OperationStore(
                storage: FileOperationStorage(path: path, flusher: flusher), now: Sample.start)
            #expect(throws: OperationStoreError.writeFailed(.io(operation: "F_FULLFSYNC", errno: code))) {
                try store.admit(Sample.receipt(Sample.key("op-1")), digest: Sample.digest("a"), now: Sample.start)
            }
            #expect(flusher.calls == [.full, .full, .full])
            #expect(!store.isAvailable)
        }
    }

    @Test func runsWhereFullFlushIsUnsupported() throws {
        try Self.withDirectory { directory in
            let path = directory + "/operations.jsonl"
            let flusher = ScriptedFlush.failing(.full, with: ENOTSUP)
            let store = try OperationStore(
                storage: FileOperationStorage(path: path, flusher: flusher), now: Sample.start)
            let ticket = try Sample.admit(store, Sample.key("op-1"))
            try store.markExecuting(ticket)
            _ = try store.finish(ticket, Sample.completed(), eventsPosted: 2)
            #expect(flusher.calls.count { $0 == .plain } == flusher.calls.count { $0 == .full })

            let restarted = try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            #expect(
                try restarted.record(for: Sample.key("op-1"), now: Sample.start)?.view
                    == OperationView(status: .completed, eventsPosted: 2))
        }
    }

    @Test func recoversRecordsAcrossARestart() throws {
        try Self.withDirectory { directory in
            let path = directory + "/operations.jsonl"
            let store = try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            let done = try Sample.admit(store, Sample.key("done"))
            try store.markExecuting(done)
            _ = try store.finish(done, Sample.completed(), eventsPosted: 3)
            let running = try Sample.admit(store, Sample.key("running"))
            try store.markExecuting(running)
            try store.recordProgress(running, eventsPosted: 1)
            _ = try Sample.admit(store, Sample.key("waiting"))
            let finished = try store.record(for: Sample.key("done"), now: Sample.start)

            let handle = try #require(FileHandle(forWritingAtPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"entry":"finish","holder_id":"cr"#.utf8))
            try handle.close()

            let restarted = try OperationStore(storage: FileOperationStorage(path: path), now: Sample.start)
            #expect(try restarted.record(for: Sample.key("done"), now: Sample.start) == finished)
            #expect(
                try restarted.record(for: Sample.key("running"), now: Sample.start)?.phase
                    == .abortedByRestart(eventsPosted: 1))
            #expect(
                try restarted.record(for: Sample.key("waiting"), now: Sample.start)?.phase == .failedBeforeExecution)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            #expect(text.hasPrefix(#"{"journal":"deskhand-operations","version":1}"#))
            #expect(text.hasSuffix("}\n"), "the torn tail is gone")

            let replayed = try restarted.lookup(Sample.key("done"), digest: Sample.digest("a"), now: Sample.start)
            guard case .replay = replayed else { throw TestFailure("no replay: \(replayed)") }
        }
    }
}
