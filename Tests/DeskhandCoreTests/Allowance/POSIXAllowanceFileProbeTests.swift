import DeskhandCore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct POSIXAllowanceFileProbeTests {
    let probe = POSIXAllowanceFileProbe()

    static func withDirectory(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskhand-allowance-\(UInt64.random(in: 0...UInt64.max))").path
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try body(directory)
    }

    static func write(_ contents: String, to path: String, mode: Int = 0o644) throws {
        #expect(FileManager.default.createFile(atPath: path, contents: Data(contents.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    @Test func reportsTheOpenedDirectoryAndFile() throws {
        try Self.withDirectory { directory in
            let contents = AllowanceSample.json()
            try Self.write(contents, to: directory + "/allowance.json")
            let result = probe.probe(
                directory: directory, name: "allowance.json", maxBytes: AllowanceReader.maxFileBytes)
            #expect(
                result
                    == .opened(
                        directory: FileStatus(kind: .directory, owner: UInt32(geteuid()), permissions: 0o755),
                        file: FileStatus(kind: .regular, owner: UInt32(geteuid()), permissions: 0o644),
                        contents: Array(contents.utf8)))
        }
    }

    @Test func readsOneByteBeyondTheLimitFromALargerFile() throws {
        try Self.withDirectory { directory in
            try Self.write(String(repeating: "x", count: 200), to: directory + "/allowance.json")
            guard
                case .opened(_, _, let contents) = probe.probe(
                    directory: directory, name: "allowance.json", maxBytes: 64)
            else {
                Issue.record("expected the file to open")
                return
            }
            #expect(contents.count == 65)
        }
    }

    @Test func reportsWritableModes() throws {
        try Self.withDirectory { directory in
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory)
            try Self.write("{}", to: directory + "/allowance.json", mode: 0o666)
            guard
                case .opened(let directoryStatus, let fileStatus, _) = probe.probe(
                    directory: directory, name: "allowance.json", maxBytes: 64)
            else {
                Issue.record("expected the file to open")
                return
            }
            #expect(directoryStatus.permissions == 0o777)
            #expect(fileStatus.permissions == 0o666)
        }
    }

    @Test func theReaderRefusesARealDirectoryNotOwnedByRoot() throws {
        try Self.withDirectory { directory in
            try Self.write(AllowanceSample.json(), to: directory + "/allowance.json")
            var owner = UInt32(geteuid())
            if owner == 0 {
                owner = 65_534
                #expect(chown(directory, owner, gid_t(0)) == 0)
            }
            let reader = AllowanceReader(
                path: directory + "/allowance.json", mac: AllowanceSample.mac, skewToleranceMs: 0)
            #expect(reader.verdict(now: AllowanceSample.during) == .invalid(.directoryNotRootOwned(owner: owner)))
        }
    }

    @Test func aMissingFileIsNotFound() throws {
        try Self.withDirectory { directory in
            guard case .fileFailed(_, .notFound) = probe.probe(directory: directory, name: "absent.json", maxBytes: 64)
            else {
                Issue.record("expected not found")
                return
            }
        }
    }

    @Test func aMissingDirectoryIsNotFound() throws {
        try Self.withDirectory { directory in
            #expect(
                probe.probe(directory: directory + "/absent", name: "a.json", maxBytes: 64)
                    == .directoryFailed(.notFound))
        }
    }

    @Test func refusesASymbolicLinkAsTheFile() throws {
        try Self.withDirectory { directory in
            try Self.write(AllowanceSample.json(), to: directory + "/target.json")
            try FileManager.default.createSymbolicLink(
                atPath: directory + "/allowance.json", withDestinationPath: "target.json")
            guard
                case .fileFailed(_, .symbolicLink) = probe.probe(
                    directory: directory, name: "allowance.json", maxBytes: 64)
            else {
                Issue.record("expected a symbolic link refusal")
                return
            }
        }
    }

    @Test func refusesASymbolicLinkAsTheDirectory() throws {
        try Self.withDirectory { directory in
            try FileManager.default.createDirectory(atPath: directory + "/real", withIntermediateDirectories: false)
            try Self.write(AllowanceSample.json(), to: directory + "/real/allowance.json")
            try FileManager.default.createSymbolicLink(atPath: directory + "/link", withDestinationPath: "real")
            let result = probe.probe(directory: directory + "/link", name: "allowance.json", maxBytes: 64)
            #expect(result == .directoryFailed(.symbolicLink) || result == .directoryFailed(.failed(errno: ENOTDIR)))
        }
    }

    @Test func readsThroughADirectoryItMaySearchButNotList() throws {
        try Self.withDirectory { directory in
            let contents = AllowanceSample.json()
            try Self.write(contents, to: directory + "/allowance.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o311], ofItemAtPath: directory)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory) }
            let result = probe.probe(
                directory: directory, name: "allowance.json", maxBytes: AllowanceReader.maxFileBytes)
            guard case .opened(let directoryStatus, _, let read) = result else {
                Issue.record("expected the file to open, got \(result)")
                return
            }
            #expect(directoryStatus.permissions == 0o311)
            #expect(read == Array(contents.utf8))
        }
    }

    @Test func aDeniedDirectoryNamesThePermissionItNeeds() {
        let reason = AllowanceInvalidReason.directoryUnreadable(errno: EACCES)
        #expect(reason.description.hasSuffix("deskhand's user needs search permission on it"))
        #expect(!AllowanceInvalidReason.directoryUnreadable(errno: ENOTDIR).description.contains("needs"))
    }

    @Test func aRegularFileAsTheDirectoryFails() throws {
        try Self.withDirectory { directory in
            try Self.write("{}", to: directory + "/plain")
            #expect(
                probe.probe(directory: directory + "/plain", name: "a.json", maxBytes: 64)
                    == .directoryFailed(.failed(errno: ENOTDIR)))
        }
    }

    @Test func aFIFOIsReportedWithoutBlocking() throws {
        try Self.withDirectory { directory in
            #expect(mkfifo(directory + "/allowance.json", 0o644) == 0)
            guard
                case .opened(_, let file, let contents) = probe.probe(
                    directory: directory, name: "allowance.json", maxBytes: 64)
            else {
                Issue.record("expected the FIFO to open")
                return
            }
            #expect(file.kind == .other)
            #expect(contents.isEmpty)
        }
    }

    @Test func aSubdirectoryAsTheFileIsReportedAsADirectory() throws {
        try Self.withDirectory { directory in
            try FileManager.default.createDirectory(
                atPath: directory + "/allowance.json", withIntermediateDirectories: false)
            guard
                case .opened(_, let file, let contents) = probe.probe(
                    directory: directory, name: "allowance.json", maxBytes: 64)
            else {
                Issue.record("expected the directory to open")
                return
            }
            #expect(file.kind == .directory)
            #expect(contents.isEmpty)
        }
    }

    @Test func readsAtMostOneByteBeyondTheLimit() throws {
        try Self.withDirectory { directory in
            try Self.write(String(repeating: "x", count: 10_000), to: directory + "/allowance.json")
            guard
                case .opened(_, _, let contents) = probe.probe(
                    directory: directory, name: "allowance.json", maxBytes: 4096)
            else {
                Issue.record("expected the file to open")
                return
            }
            #expect(contents.count == 4097)
        }
    }
}
