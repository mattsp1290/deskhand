import DeskhandCore

/// A disk that outlives the stores built on it, so a test can stop one store mid-write, decide
/// what survived, and load another the way a restarted deskhand would.
final class FakeDisk {
    /// What survives power loss: the bytes as of the last flush.
    var durable: [UInt8]?
    /// What a read sees now, including writes not yet flushed.
    var visible: [UInt8]?
    fileprivate var temporary: [UInt8]?

    init(_ text: String? = nil) {
        durable = text.map { Array($0.utf8) }
        visible = durable
    }

    var text: String { String(decoding: visible ?? [], as: UTF8.self) }
    var lines: [String] { text.split(separator: "\n").map(String.init) }

    /// What a crash leaves for the next start.
    enum Loss: CaseIterable, CustomStringConvertible {
        /// Only the process died: the kernel still has every write.
        case processOnly
        /// Power loss: everything not flushed is gone.
        case unflushed
        /// Power loss halfway through writing back what was not flushed.
        case tornUnflushed

        var description: String {
            switch self {
            case .processOnly: "process crash"
            case .unflushed: "power loss"
            case .tornUnflushed: "torn power loss"
            }
        }
    }

    func crash(_ loss: Loss) {
        temporary = nil
        switch loss {
        case .processOnly:
            durable = visible
        case .unflushed:
            visible = durable
        case .tornUnflushed:
            if let durable, let visible, visible.count > durable.count, visible.starts(with: durable) {
                let survivors = (visible.count - durable.count) / 2
                self.visible = durable + visible[durable.count..<(durable.count + survivors)]
            } else {
                visible = durable
            }
            durable = visible
        }
    }
}

/// An ``OperationStorage`` on a ``FakeDisk`` that fails or crashes at one chosen write boundary.
final class FaultyStorage: OperationStorage {
    enum Boundary: Hashable {
        case append, synchronize, writeTemporary, flushTemporary, rename, flushDirectory
    }

    enum Fault: CaseIterable, CustomStringConvertible {
        /// The write reports an error (after a short write, for an append) and the process goes on.
        case fail
        /// The process dies at the boundary (part-way through, for an append). Nothing after it runs.
        case crash

        var description: String { self == .fail ? "fail" : "crash" }
    }

    let disk: FakeDisk
    private let faultAt: Int?
    private let fault: Fault
    private(set) var boundaries: [Boundary] = []
    private(set) var crashed = false
    var readError: StorageError?

    init(_ disk: FakeDisk, fault: Fault = .fail, at index: Int? = nil) {
        self.disk = disk
        self.fault = fault
        faultAt = index
    }

    func read() throws(StorageError) -> [UInt8]? {
        if let readError { throw readError }
        return disk.visible
    }

    func append(_ bytes: [UInt8]) throws(StorageError) {
        try cross(.append) { partial in
            disk.visible = (disk.visible ?? []) + (partial ? bytes.prefix(bytes.count / 2) : bytes[...])
        }
    }

    func synchronize() throws(StorageError) {
        try cross(.synchronize) { partial in if !partial { disk.durable = disk.visible } }
    }

    func replace(with bytes: [UInt8]) throws(StorageError) {
        try cross(.writeTemporary) { partial in disk.temporary = partial ? Array(bytes.prefix(bytes.count / 2)) : bytes
        }
        try cross(.flushTemporary) { _ in }
        try cross(.rename) { partial in if !partial { disk.visible = disk.temporary } }
        try cross(.flushDirectory) { partial in if !partial { disk.durable = disk.visible } }
    }

    private func cross(_ boundary: Boundary, _ perform: (_ partial: Bool) -> Void) throws(StorageError) {
        guard !crashed else { throw .io(operation: "crashed", errno: 5) }
        let index = boundaries.count
        boundaries.append(boundary)
        guard index == faultAt else {
            perform(false)
            return
        }
        perform(true)
        if fault == .crash { crashed = true }
        throw .io(operation: "injected \(boundary)", errno: 5)
    }
}

enum Sample {
    static let principal = Principal(certificateSubject: "CN=crew-executor,O=crew")
    static let otherPrincipal = Principal(certificateSubject: "CN=someone-else,O=crew")
    static let start = Timestamp(millisecondsSinceEpoch: 1_794_000_000_000)
    static let hour: Int64 = 3_600_000
    static let day: Int64 = 24 * hour

    static func at(_ milliseconds: Int64) -> Timestamp { start.adding(milliseconds: milliseconds) }

    static func key(_ operation: String, holder: String = "crew-1", principal: Principal = principal) -> OperationKey {
        OperationKey(principal: principal, holderID: HolderID(holder)!, operationID: OperationID(operation)!)
    }

    static func digest(_ seed: String) -> RequestDigest {
        RequestDigest(sha256: SHA256Hex(hashing: Array(seed.utf8)))
    }

    static let textEdit = AppRef(bundleID: "com.apple.TextEdit", teamID: nil, name: "TextEdit")

    /// A `keyboard` last look: TextEdit in front and owning keyboard focus.
    static let measured = Measured(
        frontmostApp: textEdit, targetApp: textEdit, windowTitle: "notes.txt", globalPoint: nil, measuredAt: start)

    /// A completed result whose echoed members are deliberately wrong, so tests see the store set them.
    static func completed(eventsPosted: Int = 999) -> OperationOutcome {
        .completed(
            EffectResult(
                operationID: OperationID("unrelated")!, frameID: FrameID("frm_Zk3vQ8sN1xT5bYc2Lw9RaA")!,
                eventsPosted: eventsPosted, replayed: true, measured: SuccessMeasured(keyboard: measured)!,
                completedAt: start.adding(milliseconds: 400)))
    }

    static func aborted(_ state: BlockingState = .paused) -> OperationOutcome {
        .aborted(
            ToolError(
                .blocked(state), message: "deskhand is \(state.rawValue).", state: state.state, measured: measured))
    }

    static func failed() -> OperationOutcome {
        .failed(ToolError(.internalError, message: "The operation record could not be written.", state: .ok))
    }

    static func store(
        _ disk: FakeDisk, at now: Timestamp = start, configuration: OperationStore.Configuration = .init()
    ) throws -> OperationStore {
        try OperationStore(storage: FaultyStorage(disk), configuration: configuration, now: now)
    }

    /// Admits `key` on `store` and returns its ticket.
    static func admit(
        _ store: OperationStore, _ key: OperationKey, digest: RequestDigest = digest("a"), at now: Timestamp = start
    )
        throws -> OperationTicket
    {
        guard case .new(let ticket) = try store.admit(key, digest: digest, now: now) else {
            throw TestFailure("\(key) was not admitted")
        }
        return ticket
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
