import DeskhandCore
import Foundation
import Testing

/// Contract 12.1 and 12.7: owner-only files, refused when anything else is found at the path.
@Suite struct DurableFileTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func replacesAtomicallyWithAnOwnerOnlyFile() throws {
        try withTemporaryDirectory { directory in
            let file = DurableFile(path: directory + "/state.json")
            #expect(try file.read() == nil)
            try file.replace(with: bytes("first"))
            #expect(try file.read() == bytes("first"))
            try file.replace(with: bytes("second, longer"))
            #expect(try file.read() == bytes("second, longer"))
            try file.replace(with: [])
            #expect(try file.read() == [])

            #expect(try permissions(of: file.path) == 0o600)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == DurableFile.currentUser)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["state.json"])
        }
    }

    @Test func aLeftoverTemporaryFileDoesNotWidenPermissions() throws {
        try withTemporaryDirectory { directory in
            let file = DurableFile(path: directory + "/state.json")
            #expect(
                FileManager.default.createFile(
                    atPath: file.path + ".tmp", contents: Data("stale".utf8), attributes: [.posixPermissions: 0o644]))
            try file.replace(with: bytes("fresh"))
            #expect(try permissions(of: file.path) == 0o600)
            #expect(try file.read() == bytes("fresh"))
        }
    }

    @Test(arguments: [0o644, 0o640, 0o604, 0o700, 0o4600, 0o666])
    func refusesWiderPermissions(_ mode: Int) throws {
        try withTemporaryDirectory { directory in
            let file = DurableFile(path: directory + "/state.json")
            try file.replace(with: bytes("x"))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            #expect(throws: StorageError.permissionsTooWide(mode: UInt32(mode))) { try file.read() }
            #expect(throws: StorageError.permissionsTooWide(mode: UInt32(mode))) { try file.openForAppending() }
        }
    }

    @Test func acceptsANarrowerFile() throws {
        try withTemporaryDirectory { directory in
            let file = DurableFile(path: directory + "/state.json")
            try file.replace(with: bytes("x"))
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            #expect(try file.read() == bytes("x"))
        }
    }

    /// The directory is checked before the file, so a file owned by another uid shows only where
    /// that uid does not own the directory as well: as root, which can hand the file away.
    @Test(.enabled(if: geteuid() == 0, "only root can give a file away"))
    func refusesAFileOwnedBySomeoneElse() throws {
        try withTemporaryDirectory { directory in
            let file = DurableFile(path: directory + "/state.json")
            try file.replace(with: bytes("x"))
            #expect(chown(file.path, 65_534, 0) == 0)
            let refusal = StorageError.wrongOwner(owner: 65_534, expected: 0)
            #expect(throws: refusal) { try file.read() }
            #expect(throws: refusal) { try file.openForAppending() }
        }
    }

    /// Re-reviews A3 and B4: whoever can write the directory can remove the file, and a missing
    /// file reads as empty. Each call checks the directory before it touches the file.
    @Test func refusesADirectoryOwnedBySomeoneElse() throws {
        try withTemporaryDirectory { directory in
            try DurableFile(path: directory + "/state.json").replace(with: bytes("x"))
            let stranger = DurableFile.currentUser &+ 1
            let file = DurableFile(path: directory + "/state.json", owner: stranger)
            let refusal = StorageError.directoryWrongOwner(owner: DurableFile.currentUser, expected: stranger)
            #expect(throws: refusal) { try file.read() }
            #expect(throws: refusal) { try file.openForAppending() }
            #expect(throws: refusal) { try file.replace(with: bytes("y")) }
            #expect(try DurableFile(path: file.path).read() == bytes("x"))
        }
    }

    @Test(arguments: [0o777, 0o775, 0o757, 0o1777, 0o730])
    func refusesADirectoryOthersCanWrite(_ mode: Int) throws {
        try withTemporaryDirectory { directory in
            let file = DurableFile(path: directory + "/state.json")
            try file.replace(with: bytes("x"))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
            let refusal = StorageError.directoryWritableByOthers(mode: UInt32(mode))
            #expect(throws: refusal) { try file.read() }
            #expect(throws: refusal) { try file.openForAppending() }
            #expect(throws: refusal) { try file.replace(with: bytes("y")) }
        }
    }

    @Test func refusesADirectoryReachedThroughASymbolicLink() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(atPath: directory + "/real", withIntermediateDirectories: false)
            try DurableFile(path: directory + "/real/state.json").replace(with: bytes("x"))
            try FileManager.default.createSymbolicLink(atPath: directory + "/link", withDestinationPath: "real")
            let file = DurableFile(path: directory + "/link/state.json")
            for call in [{ _ = try file.read() }, { _ = try file.openForAppending() }, { try file.replace(with: []) }] {
                do {
                    try call()
                    Issue.record("followed the link")
                } catch {
                    let error = error as? StorageError
                    #expect(
                        error == .io(operation: "open directory", errno: ELOOP)
                            || error == .io(operation: "open directory", errno: ENOTDIR))
                }
            }
        }
    }

    /// A missing directory is not an empty file.
    @Test func aMissingDirectoryIsAnError() throws {
        try withTemporaryDirectory { directory in
            let file = DurableFile(path: directory + "/absent/state.json")
            #expect(throws: StorageError.io(operation: "open directory", errno: ENOENT)) { try file.read() }
            #expect(throws: StorageError.io(operation: "open directory", errno: ENOENT)) {
                try file.replace(with: [])
            }
        }
    }

    @Test func acceptsANarrowerDirectory() throws {
        try withTemporaryDirectory { directory in
            let file = DurableFile(path: directory + "/state.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            try file.replace(with: bytes("x"))
            #expect(try file.read() == bytes("x"))
        }
    }

    @Test func refusesASymbolicLink() throws {
        try withTemporaryDirectory { directory in
            let target = DurableFile(path: directory + "/elsewhere.json")
            try target.replace(with: bytes("x"))
            let file = DurableFile(path: directory + "/state.json")
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target.path)
            #expect(throws: StorageError.io(operation: "open", errno: ELOOP)) { try file.read() }
            #expect(throws: StorageError.io(operation: "open", errno: ELOOP)) { try file.openForAppending() }
        }
    }

    @Test func refusesADirectoryAndAFIFOWithoutBlocking() throws {
        try withTemporaryDirectory { directory in
            let fifo = directory + "/fifo"
            #expect(mkfifo(fifo, 0o600) == 0)
            #expect(throws: StorageError.notRegularFile) { try DurableFile(path: fifo).read() }
            try FileManager.default.createDirectory(atPath: directory + "/sub", withIntermediateDirectories: false)
            #expect(throws: StorageError.notRegularFile) { try DurableFile(path: directory + "/sub").read() }
        }
    }

    @Test func appendsThroughOneDescriptorAndFlushesFully() throws {
        try withTemporaryDirectory { directory in
            let flusher = ScriptedFlush()
            let file = DurableFile(path: directory + "/journal", flusher: flusher)
            try file.replace(with: bytes("header\n"))
            #expect(flusher.calls == [.full, .full], "the temporary file, then the directory")

            let appender = try file.openForAppending()
            try appender.append(bytes("one\n"))
            try appender.append(bytes("two\n"))
            try appender.synchronize()
            #expect(flusher.calls == [.full, .full, .full])
            #expect(try file.read() == bytes("header\none\ntwo\n"))
            #expect(try permissions(of: file.path) == 0o600)
        }
    }

    @Test func appendingNeedsTheFileToExist() throws {
        try withTemporaryDirectory { directory in
            #expect(throws: StorageError.io(operation: "open", errno: ENOENT)) {
                try DurableFile(path: directory + "/journal").openForAppending()
            }
        }
    }
}

/// B3: `F_FULLFSYNC` falls back to `fsync` only where the file system does not support it. Every
/// other flush error reaches the caller, because the bytes may not be on stable storage.
@Suite struct DurableFileFlushTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test(arguments: [ENOTSUP, EINVAL])
    func fallsBackToFsyncWhereFullFlushIsUnsupported(_ code: Int32) throws {
        try withTemporaryDirectory { directory in
            let flusher = ScriptedFlush.failing(.full, with: code)
            let file = DurableFile(path: directory + "/journal", flusher: flusher)
            try file.replace(with: bytes("header\n"))
            #expect(flusher.calls == [.full, .plain, .full, .plain])

            let appender = try file.openForAppending()
            try appender.append(bytes("entry\n"))
            try appender.synchronize()
            #expect(flusher.calls.suffix(2) == [.full, .plain])
            #expect(try file.read() == bytes("header\nentry\n"))
        }
    }

    @Test(arguments: [EIO, ENOSPC, ENOTTY, EBADF])
    func surfacesEveryOtherFullFlushError(_ code: Int32) throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/journal"
            try DurableFile(path: path).replace(with: bytes("old\n"))
            let flusher = ScriptedFlush.failing(.full, with: code)
            let file = DurableFile(path: path, flusher: flusher)

            #expect(throws: StorageError.io(operation: "F_FULLFSYNC", errno: code)) {
                try file.replace(with: bytes("new\n"))
            }
            #expect(flusher.calls == [.full], "no fsync stands in for a failed F_FULLFSYNC")
            #expect(try file.read() == bytes("old\n"), "the unflushed file was never renamed into place")

            let appender = try file.openForAppending()
            try appender.append(bytes("entry\n"))
            #expect(throws: StorageError.io(operation: "F_FULLFSYNC", errno: code)) { try appender.synchronize() }
            #expect(flusher.calls == [.full, .full])
        }
    }

    @Test func surfacesAFailedFallback() throws {
        try withTemporaryDirectory { directory in
            let flusher = ScriptedFlush { call, _ in call == .full ? ENOTSUP : EIO }
            let file = DurableFile(path: directory + "/journal", flusher: flusher)
            #expect(throws: StorageError.io(operation: "fsync", errno: EIO)) { try file.replace(with: bytes("x")) }
            #expect(flusher.calls == [.full, .plain])
        }
    }

    /// The write that fails late: the new bytes are in place, but the rename may not survive power
    /// loss, so the caller is told it failed.
    @Test func aFailedDirectoryFlushLeavesTheNewBytesInPlace() throws {
        try withTemporaryDirectory { directory in
            let flusher = ScriptedFlush.failing(.full, with: EIO, at: 1)
            let file = DurableFile(path: directory + "/journal", flusher: flusher)
            #expect(throws: StorageError.io(operation: "F_FULLFSYNC", errno: EIO)) {
                try file.replace(with: bytes("new\n"))
            }
            let contents = try file.read()
            #expect(contents == bytes("new\n"))
        }
    }
}
