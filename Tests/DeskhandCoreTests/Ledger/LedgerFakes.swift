import DeskhandCore

/// Thrown by the fakes at the boundary chosen to crash at. The test then drops the ledger value, as
/// a dead process would, and recovers from the bytes left on the fake disk.
struct LedgerCrash: Error {}

struct LedgerFault: Error {}

enum LedgerEvent: Hashable, Sendable, CustomStringConvertible {
    case down(HeldInput)
    case up(HeldInput)

    var description: String {
        switch self {
        case .down(let input): "\(input) down"
        case .up(let input): "\(input) up"
        }
    }
}

/// A point where a process can die: on each side of a storage write and of a posted event.
enum LedgerBoundary: Hashable, Sendable, CustomStringConvertible {
    case beforeWrite
    case afterWrite
    case beforePost(LedgerEvent)
    case afterPost(LedgerEvent)

    var description: String {
        switch self {
        case .beforeWrite: "before write"
        case .afterWrite: "after write"
        case .beforePost(let event): "before \(event)"
        case .afterPost(let event): "after \(event)"
        }
    }
}

/// One fake Mac: a disk that survives crashes, the input its event system holds down, and the
/// boundary at which the process is to die. After the crash every write and post fails without
/// effect, as nothing more happens in a dead process, until `restart()`.
final class LedgerMachine {
    private(set) var disk: [UInt8]?
    /// What the Mac holds down now. A key-up for something not down changes nothing.
    private(set) var held: Set<HeldInput> = []
    private(set) var posted: [LedgerEvent] = []
    private(set) var trace: [LedgerBoundary] = []
    private(set) var writes = 0
    private(set) var crashedAt: LedgerBoundary?
    /// Index into `trace` of the boundary to crash at.
    var crashAt: Int?
    var failWrites = false
    var failPosts = false

    init(crashAt: Int? = nil, disk: [UInt8]? = nil) {
        self.crashAt = crashAt
        self.disk = disk
    }

    /// A new process on the same Mac: the disk and the held input survive.
    func restart() { crashedAt = nil }

    var store: LedgerFakeStore { LedgerFakeStore(machine: self) }

    func post(_ event: LedgerEvent) throws {
        if failPosts { throw LedgerFault() }
        try reach(.beforePost(event))
        posted.append(event)
        switch event {
        case .down(let input): held.insert(input)
        case .up(let input): held.remove(input)
        }
        try reach(.afterPost(event))
    }

    func postRelease(_ input: HeldInput) throws { try post(.up(input)) }

    fileprivate func write(_ bytes: [UInt8]) throws {
        if failWrites { throw LedgerFault() }
        try reach(.beforeWrite)
        disk = bytes
        writes += 1
        try reach(.afterWrite)
    }

    private func reach(_ boundary: LedgerBoundary) throws(LedgerCrash) {
        guard crashedAt == nil else { throw LedgerCrash() }
        if trace.count == crashAt {
            crashAt = nil
            crashedAt = boundary
            throw LedgerCrash()
        }
        trace.append(boundary)
    }
}

struct LedgerFakeStore: HeldInputStore {
    let machine: LedgerMachine

    func load() throws -> [UInt8]? { machine.disk }
    func replace(with bytes: [UInt8]) throws { try machine.write(bytes) }
}

/// What an effect holds, driven the way the executor drives the ledger (contract 12.3 step 5):
/// each down only after `willPress` returned, each `didRelease` only after the up was posted.
enum LedgerScenario: String, CaseIterable, Sendable {
    /// `keyboard` `press` with `control`, `shift` and `command`.
    case chord
    /// `pointer` `drag` with `option`.
    case drag
    /// A `press` of `return`, then a right click with `shift`.
    case twoOperations

    var operations: [[HeldInput]] {
        switch self {
        case .chord: [[.modifier(.control), .modifier(.shift), .modifier(.command), .key(.t)]]
        case .drag: [[.modifier(.option), .button(.left)]]
        case .twoOperations: [[.key(.return)], [.modifier(.shift), .button(.right)]]
        }
    }

    func run(_ ledger: inout HeldInputLedger, on machine: LedgerMachine) throws {
        for inputs in operations {
            for input in inputs {
                try ledger.willPress(input)
                try machine.post(.down(input))
            }
            for input in inputs.reversed() {
                try machine.post(.up(input))
                try ledger.didRelease(input)
            }
        }
    }

    /// The boundaries a run reaches when nothing crashes.
    func trace() throws -> [LedgerBoundary] {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try run(&ledger, on: machine)
        return machine.trace
    }
}
