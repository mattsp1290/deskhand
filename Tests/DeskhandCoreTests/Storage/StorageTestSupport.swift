import DeskhandCore
import Foundation
import Synchronization

func withTemporaryDirectory(_ body: (String) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("deskhand-storage-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try body(directory)
}

func permissions(of path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard let mode = attributes[.posixPermissions] as? Int else { throw StorageTestFailure("no mode for \(path)") }
    return mode
}

struct StorageTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class ScriptedFlush: StorageFlush {
    enum Call: Hashable, Sendable {
        case full
        case plain
    }

    private let fault: @Sendable (_ call: Call, _ index: Int) -> Int32?
    private let log = Mutex<[Call]>([])

    init(_ fault: @escaping @Sendable (_ call: Call, _ index: Int) -> Int32? = { _, _ in nil }) {
        self.fault = fault
    }

    static func failing(_ call: Call, with code: Int32, at index: Int? = nil) -> ScriptedFlush {
        ScriptedFlush { made, madeIndex in made == call && (index == nil || index == madeIndex) ? code : nil }
    }

    var calls: [Call] { log.withLock { $0 } }

    func fullFlush(_ descriptor: Int32) throws(StorageError) {
        if let code = record(.full) { throw .io(operation: "F_FULLFSYNC", errno: code) }
        try SystemStorageFlush().fullFlush(descriptor)
    }

    func flush(_ descriptor: Int32) throws(StorageError) {
        if let code = record(.plain) { throw .io(operation: "fsync", errno: code) }
        try SystemStorageFlush().flush(descriptor)
    }

    private func record(_ call: Call) -> Int32? {
        let index = log.withLock { calls in
            calls.append(call)
            return calls.count { $0 == call } - 1
        }
        return fault(call, index)
    }
}
