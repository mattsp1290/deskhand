import Testing

@testable import DeskhandCore

@Suite(.timeLimit(.minutes(1))) struct VerifiedSnapshotTests {
    static func compacted(_ count: Int) throws -> FakeDisk {
        let disk = FakeDisk()
        let store = try Sample.store(disk)
        for index in 0..<count {
            let ticket = try Sample.admit(store, Sample.key("op-\(index)"))
            try store.markExecuting(ticket)
            _ = try store.finish(ticket, Sample.completed(), eventsPosted: 4)
        }
        _ = try Sample.store(disk)
        return disk
    }

    static func refusesUnchanged(_ bytes: [UInt8]) {
        let disk = FakeDisk()
        disk.visible = bytes
        disk.durable = bytes
        let storage = FaultyStorage(disk)
        #expect(throws: OperationStoreLoadError.self) {
            try OperationStore(storage: storage, now: Sample.start)
        }
        #expect(disk.visible == bytes)
        #expect(disk.durable == bytes)
        #expect(storage.boundaries.isEmpty, "a rejected load must not replace the retained records")
    }

    @Test(arguments: [0, 1, 3])
    func everySnapshotPrefixMustBeComplete(count: Int) throws {
        let bytes = try #require(Self.compacted(count).visible)
        for end in 0..<bytes.count { Self.refusesUnchanged(Array(bytes.prefix(end))) }
        let disk = FakeDisk()
        disk.visible = bytes
        let store = try Sample.store(disk)
        for index in 0..<count {
            let key = Sample.key("op-\(index)")
            guard case .replay = try store.admit(Sample.receipt(key), digest: Sample.digest("a"), now: Sample.start)
            else {
                Issue.record("acknowledged operation was admitted again")
                continue
            }
        }
    }

    @Test(arguments: [1, 3])
    func corruptionOfEveryCompactedRecordFailsClosed(count: Int) throws {
        let disk = try Self.compacted(count)
        let lines = disk.lines
        for index in 1...count {
            var damaged = lines
            damaged[index].replaceSubrange(damaged[index].startIndex...damaged[index].startIndex, with: "!")
            Self.refusesUnchanged(Array((damaged.joined(separator: "\n") + "\n").utf8))
            damaged = lines
            damaged[index] = damaged[index].replacing("\"events_posted\":4", with: "\"events_posted\":5")
            Self.refusesUnchanged(Array((damaged.joined(separator: "\n") + "\n").utf8))
        }
    }

    @Test(arguments: ["{\"entry\":\"fin", "{\"entry\":\"finish\"\u{0}\u{0}\u{0}\n", "\u{0}\u{0}\u{0}\u{0}\n"])
    func tornAppendAfterVerifiedSnapshotPreservesReplay(tail: String) throws {
        let disk = try Self.compacted(3)
        disk.visible! += tail.utf8
        let store = try Sample.store(disk)
        for index in 0..<3 {
            let key = Sample.key("op-\(index)")
            guard case .replay = try store.admit(Sample.receipt(key), digest: Sample.digest("a"), now: Sample.start)
            else {
                Issue.record("torn append lost retained result")
                continue
            }
        }
    }

    @Test func invalidFramingAndSnapshotMembershipFailClosed() throws {
        let disk = try Self.compacted(1)
        let lines = disk.lines
        let header = try #require(JSONValue(parsing: lines[0]).objectValue)
        let payload = Array((lines[1] + "\n").utf8)
        let changes: [(String, JSONValue)] = [
            ("record_count", 0), ("record_count", 2), ("record_count", -1), ("record_count", 1.5),
            ("payload_bytes", -1), ("payload_bytes", JSONValue(payload.count + 1)),
            ("payload_bytes", .number(9_007_199_254_740_992)), ("payload_bytes", 1.5),
            ("payload_sha256", .string(String(repeating: "0", count: 64))), ("payload_sha256", "invalid"),
            ("version", 3), ("unexpected", true),
        ]
        for (field, value) in changes {
            var invalid = header
            invalid[field] = value
            Self.refusesUnchanged(try OperationJournal.line(invalid) + payload)
        }
        for field in header.keys {
            var invalid = header
            invalid[field] = nil
            Self.refusesUnchanged(try OperationJournal.line(invalid) + payload)
        }
        let key = Sample.key("op-0")
        let transition = try OperationJournal.Entry.transition(key, .execute).line()
        var malformedRecord = try #require(JSONValue(parsing: lines[1]).objectValue)
        malformedRecord["events_posted"] = -1
        for body in [
            payload + payload, transition, try OperationJournal.line(malformedRecord), Array(payload.dropLast()),
        ] {
            var invalid = header
            invalid["record_count"] = JSONValue(body == payload + payload ? 2 : 1)
            invalid["payload_bytes"] = JSONValue(body.count)
            invalid["payload_sha256"] = .string(SHA256Hex(hashing: body).description)
            Self.refusesUnchanged(try OperationJournal.line(invalid) + body)
        }
    }

    @Test func equalAdmissionTimesHaveStableSnapshotBytes() throws {
        let disk = try Self.compacted(3)
        let records = Array(try OperationJournal.replay(#require(disk.visible)).values)
        #expect(try OperationJournal.snapshot(records) == OperationJournal.snapshot(records.reversed()))
    }

    @Test func legacyVersionIsExplicitlyRejectedWithoutReplacement() throws {
        let bytes = Array("{\"journal\":\"deskhand-operations\",\"version\":1}\n".utf8)
        Self.refusesUnchanged(bytes)
        let error = try #require(throws: OperationStoreLoadError.self) { try OperationJournal.replay(bytes) }
        guard case .corrupt(_, let reason) = error else {
            Issue.record("expected corruption")
            return
        }
        #expect(reason.contains("unsupported legacy version 1"))
    }
}
