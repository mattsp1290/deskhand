enum OperationJournal {
    static let format = "deskhand-operations"
    static let version = 2
    static let admittedAtRange = 0...253_402_300_799_999
    static let countRange = 0...JSONValue.maxExactInteger

    private struct SnapshotHeader {
        let recordCount: Int
        let payloadBytes: Int
        let payloadSHA256: SHA256Hex

        var object: JSONObject {
            [
                "journal": .string(format), "version": JSONValue(version),
                "record_count": JSONValue(recordCount), "payload_bytes": JSONValue(payloadBytes),
                "payload_sha256": .string(payloadSHA256.description),
            ]
        }
    }

    private struct VerifiedSnapshot {
        let records: [OperationKey: OperationRecord]
        let appendOffset: Int
        let appendLine: Int
    }

    static func snapshot(_ records: some Sequence<OperationRecord>) throws(NonFiniteNumberError) -> [UInt8] {
        var payload: [UInt8] = []
        var count = 0
        let ordered = records.sorted {
            ($0.admittedAt, $0.key.principal.certificateSubject, $0.key.holderID.rawValue, $0.key.operationID.rawValue)
                < (
                    $1.admittedAt, $1.key.principal.certificateSubject, $1.key.holderID.rawValue,
                    $1.key.operationID.rawValue
                )
        }
        for record in ordered {
            payload += try Entry.record(record).line()
            count += 1
        }
        let header = SnapshotHeader(
            recordCount: count, payloadBytes: payload.count, payloadSHA256: SHA256Hex(hashing: payload))
        return try line(header.object) + payload
    }

    static func line(_ object: JSONObject) throws(NonFiniteNumberError) -> [UInt8] {
        try JSONValue.object(object).canonicalBytes() + [UInt8(ascii: "\n")]
    }

    static func replay(_ bytes: [UInt8]) throws(OperationStoreLoadError) -> [OperationKey: OperationRecord] {
        let snapshot = try verifySnapshot(bytes)
        var records = snapshot.records
        var lines = bytes[snapshot.appendOffset...].split(
            separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        lines.removeLast()
        for (offset, line) in lines.enumerated() {
            let lineNumber = snapshot.appendLine + offset
            let entry: Entry
            do throws(EntryError) {
                entry = try Entry(decoding: line)
            } catch {
                if error.isTorn, offset == lines.count - 1 { break }
                throw .corrupt(line: lineNumber, reason: error.reason)
            }
            try entry.apply(to: &records, line: lineNumber)
        }
        return records
    }

    private static func verifySnapshot(_ bytes: [UInt8]) throws(OperationStoreLoadError) -> VerifiedSnapshot {
        guard let headerEnd = bytes.firstIndex(of: UInt8(ascii: "\n")),
            let object = try? JSONValue(parsing: bytes[..<headerEnd]).objectValue,
            object["journal"] == .string(format)
        else { throw .corrupt(line: 1, reason: "missing \(format) version \(version) header") }
        if object["version"] == JSONValue(1) {
            throw .corrupt(
                line: 1, reason: "unsupported legacy version 1 journal; snapshot integrity cannot be verified")
        }
        let payloadStart = headerEnd + 1
        guard object["version"] == JSONValue(version),
            Set(object.keys) == ["journal", "version", "record_count", "payload_bytes", "payload_sha256"],
            let byteCount = object["payload_bytes"]?.integer(in: 0...(bytes.count - payloadStart)),
            let recordCount = object["record_count"]?.integer(in: 0...byteCount),
            let hash = object["payload_sha256"]?.stringValue.flatMap(SHA256Hex.init(hex:))
        else { throw .corrupt(line: 1, reason: "invalid or truncated snapshot header") }
        let header = SnapshotHeader(recordCount: recordCount, payloadBytes: byteCount, payloadSHA256: hash)
        let appendOffset = payloadStart + header.payloadBytes
        let payload = bytes[payloadStart..<appendOffset]
        guard SHA256Hex(hashing: payload) == header.payloadSHA256,
            payload.isEmpty || payload.last == UInt8(ascii: "\n")
        else { throw .corrupt(line: 1, reason: "snapshot payload is incomplete or its digest does not match") }
        var lines = payload.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        lines.removeLast()
        guard lines.count == header.recordCount else {
            throw .corrupt(line: 1, reason: "snapshot record count does not match")
        }
        var records: [OperationKey: OperationRecord] = [:]
        for (offset, line) in lines.enumerated() {
            let entry: Entry
            do throws(EntryError) {
                entry = try Entry(decoding: line)
            } catch { throw .corrupt(line: offset + 2, reason: error.reason) }
            guard case .record(let record) = entry, records[record.key] == nil else {
                throw .corrupt(line: offset + 2, reason: "snapshot requires unique record entries")
            }
            records[record.key] = record
        }
        return VerifiedSnapshot(records: records, appendOffset: appendOffset, appendLine: lines.count + 2)
    }

    enum Entry: Hashable {
        case record(OperationRecord)
        case transition(OperationKey, OperationTransition)

        func line() throws(NonFiniteNumberError) -> [UInt8] {
            switch self {
            case .record(let record):
                var object = Self.fields(record.key, entry: "record")
                object["digest"] = .string(record.digest.description)
                object["admitted_at_ms"] = JSONValue(record.admittedAt.millisecondsSinceEpoch)
                object["status"] = .string(record.phase.status.rawValue)
                object["events_posted"] = JSONValue(record.phase.eventsPosted)
                if case .ended(let ending, _) = record.phase { object["result"] = .object(ending.structuredContent) }
                return try OperationJournal.line(object)
            case .transition(let key, let transition):
                var object: JSONObject
                switch transition {
                case .execute:
                    object = Self.fields(key, entry: "execute")
                case .progress(let count):
                    object = Self.fields(key, entry: "progress")
                    object["events_posted"] = JSONValue(count)
                case .finish(let ending, let count):
                    object = Self.fields(key, entry: "finish")
                    object["status"] = .string(ending.status.rawValue)
                    object["events_posted"] = JSONValue(count)
                    object["result"] = .object(ending.structuredContent)
                case .interrupt(let count):
                    object = Self.fields(key, entry: "interrupt")
                    object["events_posted"] = JSONValue(count)
                case .restart:
                    preconditionFailure("restart is applied at load and never journaled")
                }
                return try OperationJournal.line(object)
            }
        }

        private static func fields(_ key: OperationKey, entry: String) -> JSONObject {
            [
                "entry": .string(entry), "principal": .string(key.principal.certificateSubject),
                "holder_id": .string(key.holderID.rawValue), "operation_id": .string(key.operationID.rawValue),
            ]
        }

        init(decoding line: ArraySlice<UInt8>) throws(EntryError) {
            let parsed: JSONValue
            do throws(JSONParseError) {
                parsed = try JSONValue(parsing: line)
            } catch {
                throw EntryError("not JSON: \(error)", isTorn: true)
            }
            guard let object = parsed.objectValue else { throw EntryError("not an object") }
            let fields = Fields(object)
            let key = OperationKey(
                principal: Principal(certificateSubject: try fields.string("principal")),
                holderID: try fields.identifier("holder_id", HolderID.self),
                operationID: try fields.identifier("operation_id", OperationID.self))
            switch try fields.string("entry") {
            case "record":
                guard let sha256 = SHA256Hex(hex: try fields.string("digest")) else { throw EntryError("bad digest") }
                let status = try fields.status()
                let count = try fields.count()
                let phase: OperationPhase? =
                    switch status {
                    case .accepted: count == 0 ? .accepted : nil
                    case .executing: .executing(eventsPosted: count)
                    case .failedBeforeExecution: count == 0 ? .failedBeforeExecution : nil
                    case .abortedByRestart: .abortedByRestart(eventsPosted: count)
                    case .completed, .aborted, .failed: .ended(try fields.ending(status), eventsPosted: count)
                    }
                guard let phase else { throw EntryError("\(status.rawValue) with \(count) events posted") }
                let admittedAt = try fields.integer("admitted_at_ms", in: OperationJournal.admittedAtRange)
                self = .record(
                    OperationRecord(
                        key: key, digest: RequestDigest(sha256: sha256),
                        admittedAt: Timestamp(millisecondsSinceEpoch: Int64(admittedAt)), phase: phase))
            case "execute": self = .transition(key, .execute)
            case "progress": self = .transition(key, .progress(eventsPosted: try fields.count()))
            case "finish":
                self = .transition(
                    key, .finish(try fields.ending(try fields.status()), eventsPosted: try fields.count()))
            case "interrupt": self = .transition(key, .interrupt(eventsPosted: try fields.count()))
            case let other: throw EntryError("unknown entry \(other)")
            }
        }

        func apply(to records: inout [OperationKey: OperationRecord], line: Int) throws(OperationStoreLoadError) {
            switch self {
            case .record(let record):
                if let existing = records[record.key], !existing.phase.isFinal {
                    throw .corrupt(line: line, reason: "\(record.key) admitted again while \(existing.phase.status)")
                }
                records[record.key] = record
            case .transition(let key, let transition):
                guard var record = records[key] else { throw .corrupt(line: line, reason: "\(key) has no record") }
                guard let next = record.phase.applying(transition) else {
                    throw .corrupt(line: line, reason: "\(key) cannot change from \(record.phase.status)")
                }
                record.phase = next
                records[key] = record
            }
        }
    }

    struct EntryError: Error {
        let reason: String
        let isTorn: Bool

        init(_ reason: String, isTorn: Bool = false) {
            self.reason = reason
            self.isTorn = isTorn
        }
    }

    private struct Fields {
        let object: JSONObject
        init(_ object: JSONObject) { self.object = object }

        func string(_ name: String) throws(EntryError) -> String {
            guard let value = object[name]?.stringValue else { throw EntryError("\(name) missing") }
            return value
        }

        func identifier<ID: RestrictedIdentifier>(_ name: String, _: ID.Type) throws(EntryError) -> ID {
            guard let id = ID(try string(name)) else { throw EntryError("bad \(name)") }
            return id
        }

        func integer(_ name: String, in range: ClosedRange<Int>) throws(EntryError) -> Int {
            guard let value = object[name]?.integer(in: range) else {
                throw EntryError("\(name) is not an integer from \(range.lowerBound) to \(range.upperBound)")
            }
            return value
        }

        func count() throws(EntryError) -> Int { try integer("events_posted", in: OperationJournal.countRange) }

        func status() throws(EntryError) -> OperationStatus {
            guard let status = OperationStatus(rawValue: try string("status")) else { throw EntryError("bad status") }
            return status
        }

        func ending(_ status: OperationStatus) throws(EntryError) -> OperationEnding {
            guard case .object(let content) = object["result"],
                let ending = OperationEnding(status: status, structuredContent: content)
            else { throw EntryError("\(status.rawValue) without a result") }
            return ending
        }
    }
}
