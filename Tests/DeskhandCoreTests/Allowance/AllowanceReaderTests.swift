import DeskhandCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct AllowanceReaderTests {
    typealias Status = FileStatus

    @Test func aValidAllowanceIsValidUntilItsExpiry() {
        let reader = AllowanceSample.reader(AllowanceSample.opened())
        #expect(reader.verdict(now: AllowanceSample.during) == .valid(expiresAt: AllowanceSample.expiresAt))
    }

    @Test func probesTheConfiguredDirectoryAndName() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened())
        _ = AllowanceSample.reader(probe).read()
        #expect(
            probe.calls == [
                .init(
                    directory: "/var/run/birbhomes", name: "deskhand-allowance.json",
                    maxBytes: AllowanceReader.maxFileBytes)
            ])
    }

    @Test func aFileAtTheRootIsProbedInTheRootDirectory() {
        let probe = FakeAllowanceProbe(AllowanceSample.opened())
        _ = AllowanceReader(path: "/allowance.json", mac: AllowanceSample.mac, skewToleranceMs: 0, probe: probe).read()
        #expect(probe.calls.map(\.directory) == ["/"])
        #expect(probe.calls.map(\.name) == ["allowance.json"])
    }

    @Test func takesPathMacAndSkewFromTheConfiguration() throws {
        let config = try DeskhandConfig(parsing: Array(ConfigFixtures.example.utf8))
        let reader = AllowanceReader(config: config, probe: FakeAllowanceProbe(.directoryFailed(.notFound)))
        #expect(reader.path == config.allowance.path)
        #expect(reader.mac == config.mac)
        #expect(reader.skewToleranceMs == config.allowance.skewToleranceMs)
    }

    struct FileCase: CustomTestStringConvertible, Sendable {
        let label: String
        let probe: AllowanceProbe
        let expected: AllowanceSnapshot
        var testDescription: String { label }
    }

    static let fileCases: [FileCase] = [
        FileCase(label: "directory missing", probe: .directoryFailed(.notFound), expected: .missing),
        FileCase(
            label: "directory is a symbolic link", probe: .directoryFailed(.symbolicLink),
            expected: .invalid(.directorySymbolicLink)),
        FileCase(
            label: "directory unreadable", probe: .directoryFailed(.failed(errno: 13)),
            expected: .invalid(.directoryUnreadable(errno: 13))),
        FileCase(
            label: "file missing", probe: .fileFailed(directory: AllowanceSample.rootDirectory, error: .notFound),
            expected: .missing),
        FileCase(
            label: "file is a symbolic link",
            probe: .fileFailed(directory: AllowanceSample.rootDirectory, error: .symbolicLink),
            expected: .invalid(.symbolicLink)),
        FileCase(
            label: "file unreadable",
            probe: .fileFailed(directory: AllowanceSample.rootDirectory, error: .failed(errno: 13)),
            expected: .invalid(.unreadable(errno: 13))),
        FileCase(
            label: "file missing from a directory not owned by root",
            probe: .fileFailed(directory: Status(kind: .directory, owner: 501, permissions: 0o755), error: .notFound),
            expected: .invalid(.directoryNotRootOwned(owner: 501))),
        FileCase(
            label: "directory is not a directory",
            probe: AllowanceSample.opened(directory: Status(kind: .regular, owner: 0, permissions: 0o755)),
            expected: .invalid(.directoryNotADirectory)),
        FileCase(
            label: "directory owned by a user",
            probe: AllowanceSample.opened(directory: Status(kind: .directory, owner: 501, permissions: 0o755)),
            expected: .invalid(.directoryNotRootOwned(owner: 501))),
        FileCase(
            label: "directory group writable",
            probe: AllowanceSample.opened(directory: Status(kind: .directory, owner: 0, permissions: 0o775)),
            expected: .invalid(.directoryWritableByGroupOrOthers(permissions: 0o775))),
        FileCase(
            label: "directory world writable",
            probe: AllowanceSample.opened(directory: Status(kind: .directory, owner: 0, permissions: 0o757)),
            expected: .invalid(.directoryWritableByGroupOrOthers(permissions: 0o757))),
        FileCase(
            label: "directory sticky and world writable",
            probe: AllowanceSample.opened(directory: Status(kind: .directory, owner: 0, permissions: 0o1777)),
            expected: .invalid(.directoryWritableByGroupOrOthers(permissions: 0o1777))),
        FileCase(
            label: "file is a directory",
            probe: AllowanceSample.opened(file: Status(kind: .directory, owner: 0, permissions: 0o755), contents: ""),
            expected: .invalid(.notRegularFile)),
        FileCase(
            label: "file is a device or FIFO",
            probe: AllowanceSample.opened(file: Status(kind: .other, owner: 0, permissions: 0o644), contents: ""),
            expected: .invalid(.notRegularFile)),
        FileCase(
            label: "file owned by a user",
            probe: AllowanceSample.opened(file: Status(kind: .regular, owner: 501, permissions: 0o644)),
            expected: .invalid(.notRootOwned(owner: 501))),
        FileCase(
            label: "file group writable",
            probe: AllowanceSample.opened(file: Status(kind: .regular, owner: 0, permissions: 0o664)),
            expected: .invalid(.writableByGroupOrOthers(permissions: 0o664))),
        FileCase(
            label: "file world writable",
            probe: AllowanceSample.opened(file: Status(kind: .regular, owner: 0, permissions: 0o646)),
            expected: .invalid(.writableByGroupOrOthers(permissions: 0o646))),
        FileCase(
            label: "file too large",
            probe: AllowanceSample.opened(contents: String(repeating: " ", count: AllowanceReader.maxFileBytes + 1)),
            expected: .invalid(.tooLarge)),
        FileCase(
            label: "contents malformed", probe: AllowanceSample.opened(contents: "{"),
            expected: .invalid(.malformedJSON)),
        FileCase(
            label: "allowance for another Mac",
            probe: AllowanceSample.opened(contents: AllowanceSample.json(mac: #""other-mac""#)),
            expected: .invalid(.macMismatch)),
    ]

    @Test(arguments: fileCases)
    func judgesTheFile(_ fileCase: FileCase) {
        let reader = AllowanceSample.reader(fileCase.probe)
        #expect(reader.read() == fileCase.expected)
        let verdict: AllowanceVerdict =
            switch fileCase.expected {
            case .missing: .missing
            case .invalid(let reason): .invalid(reason)
            case .allowance: .valid(expiresAt: AllowanceSample.expiresAt)
            }
        #expect(reader.verdict(now: AllowanceSample.during) == verdict)
        #expect(!verdict.isValid)
    }

    @Test(arguments: [
        (Status(kind: .directory, owner: 0, permissions: 0o755), Status(kind: .regular, owner: 0, permissions: 0o644)),
        (Status(kind: .directory, owner: 0, permissions: 0o700), Status(kind: .regular, owner: 0, permissions: 0o600)),
        (Status(kind: .directory, owner: 0, permissions: 0o555), Status(kind: .regular, owner: 0, permissions: 0o444)),
    ])
    func acceptsRootOwnedEntriesThatOnlyRootCanWrite(_ directory: Status, _ file: Status) {
        let reader = AllowanceSample.reader(AllowanceSample.opened(directory: directory, file: file))
        #expect(reader.verdict(now: AllowanceSample.during).isValid)
    }

    @Test func acceptsAFileOfExactlyTheMaximumSize() {
        let padded =
            AllowanceSample.json()
            + String(repeating: " ", count: AllowanceReader.maxFileBytes - AllowanceSample.json().utf8.count)
        let reader = AllowanceSample.reader(AllowanceSample.opened(contents: padded))
        #expect(reader.verdict(now: AllowanceSample.during).isValid)
    }

    @Test(arguments: [
        (0, -1, AllowanceVerdict.invalid(.notYetValid)),
        (0, 0, .valid(expiresAt: AllowanceSample.expiresAt)),
        (5000, -5001, .invalid(.notYetValid)),
        (5000, -5000, .valid(expiresAt: AllowanceSample.expiresAt)),
        (60_000, -60_001, .invalid(.notYetValid)),
        (60_000, -60_000, .valid(expiresAt: AllowanceSample.expiresAt)),
    ])
    func skewToleranceWidensNotBefore(_ skew: Int, _ offsetFromNotBefore: Int64, _ expected: AllowanceVerdict) {
        let reader = AllowanceSample.reader(AllowanceSample.opened(), skewToleranceMs: skew)
        #expect(reader.verdict(now: AllowanceSample.notBefore.adding(milliseconds: offsetFromNotBefore)) == expected)
    }

    @Test(arguments: [0, 5000, 60_000], [(-1 as Int64, true), (0, false), (1, false)])
    func expiresAtIsExclusiveAndNeverExtendedBySkew(_ skew: Int, _ point: (offset: Int64, valid: Bool)) {
        let reader = AllowanceSample.reader(AllowanceSample.opened(), skewToleranceMs: skew)
        let verdict = reader.verdict(now: AllowanceSample.expiresAt.adding(milliseconds: point.offset))
        #expect(verdict == (point.valid ? .valid(expiresAt: AllowanceSample.expiresAt) : .invalid(.expired)))
    }

    @Test func subMillisecondBoundsAreExactAgainstAMillisecondClock() {
        let contents = AllowanceSample.json(
            notBefore: #""2026-11-14T15:00:00.0000001Z""#, expiresAt: #""2026-11-14T15:02:00.0000001Z""#)
        let reader = AllowanceSample.reader(AllowanceSample.opened(contents: contents))
        #expect(reader.verdict(now: AllowanceSample.notBefore) == .invalid(.notYetValid))
        #expect(reader.verdict(now: AllowanceSample.notBefore.adding(milliseconds: 1)).isValid)
        #expect(reader.verdict(now: AllowanceSample.expiresAt).isValid)
        #expect(reader.verdict(now: AllowanceSample.expiresAt.adding(milliseconds: 1)) == .invalid(.expired))
    }

    @Test func anAllowanceShorterThanAMillisecondIsNeverValid() {
        let contents = AllowanceSample.json(
            notBefore: #""2026-11-14T15:00:00.0000001Z""#, expiresAt: #""2026-11-14T15:00:00.0000002Z""#)
        let reader = AllowanceSample.reader(AllowanceSample.opened(contents: contents))
        for offset: Int64 in -1...2 {
            #expect(!reader.verdict(now: AllowanceSample.notBefore.adding(milliseconds: offset)).isValid)
        }
    }
}
