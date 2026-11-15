import DeskhandCore
import Testing

/// Thrown by the fakes at the boundary chosen to crash at. The test then drops the ledger value, as
/// a dead process would, and recovers from the bytes left on the fake disk.
struct LedgerCrash: Error {}

struct LedgerFault: Error {}

/// macOS virtual key codes, as the platform layer would record them.
extension HeldInput {
    static let control = HeldInput.modifier(PostedKeyCode(0x3B))
    static let shift = HeldInput.modifier(PostedKeyCode(0x38))
    static let command = HeldInput.modifier(PostedKeyCode(0x37))
    static let option = HeldInput.modifier(PostedKeyCode(0x3A))
    static let keyA = HeldInput.key(PostedKeyCode(0x00))
    static let keyT = HeldInput.key(PostedKeyCode(0x11))
    static let returnKey = HeldInput.key(PostedKeyCode(0x24))
}

/// How a write that fails behaves.
enum WriteFault: CaseIterable, Sendable, CustomStringConvertible {
    /// The write throws and the disk keeps its bytes.
    case lost
    /// The bytes reach the disk, then the write throws: the directory flush after the rename failed.
    case landed

    var description: String { self == .lost ? "lost write" : "landed write" }
}

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
    /// Every write attempted, failed or not.
    private(set) var writeAttempts = 0
    private(set) var crashedAt: LedgerBoundary?
    /// Index into `trace` of the boundary to crash at.
    var crashAt: Int?
    /// Every write fails this way while set.
    var writeFault: WriteFault?
    /// Only the write attempt with this index fails, this way.
    var faultAtWrite: (index: Int, fault: WriteFault)?
    var failPosts = false

    init(crashAt: Int? = nil, disk: [UInt8]? = nil) {
        self.crashAt = crashAt
        self.disk = disk
    }

    /// Puts `bytes` on the disk the way something other than the ledger would.
    func overwriteDisk(_ bytes: [UInt8]?) { disk = bytes }

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

    /// The entries on the disk now, as a restart would read them.
    func recorded() throws -> [HeldInput] {
        try HeldInputLedger(store: store).pending()
    }

    fileprivate func write(_ bytes: [UInt8]) throws {
        let attempt = writeAttempts
        writeAttempts += 1
        let fault = writeFault ?? faultAtWrite.flatMap { $0.index == attempt ? $0.fault : nil }
        if fault == .lost { throw LedgerFault() }
        try reach(.beforeWrite)
        disk = bytes
        writes += 1
        if fault == .landed { throw LedgerFault() }
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
    /// Two clicks of one button: the second press needs the entry that the first one's clear
    /// removed.
    case doubleClick

    var operations: [[HeldInput]] {
        switch self {
        case .chord: [[.control, .shift, .command, .keyT]]
        case .drag: [[.option, .button(.left)]]
        case .twoOperations: [[.returnKey], [.shift, .button(.right)]]
        case .doubleClick: [[.button(.left)], [.button(.left)]]
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

    /// Drives the ledger as the most forgiving executor would: it carries on after a failed clear,
    /// since that input's up was posted, and at a failed press it aborts and releases what the
    /// ledger holds. Before each down it checks that the disk records that input.
    func runCarryingOn(
        _ ledger: inout HeldInputLedger, on machine: LedgerMachine, comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        for inputs in operations {
            do {
                for input in inputs {
                    try ledger.willPress(input)
                    #expect(
                        try machine.recorded().contains(input), "\(input) down without a durable entry; \(comment)",
                        sourceLocation: sourceLocation)
                    try machine.post(.down(input))
                }
            } catch {
                _ = ledger.releasePending(authorization: { .authorized }, postRelease: machine.postRelease)
                return
            }
            for input in inputs.reversed() {
                try machine.post(.up(input))
                try? ledger.didRelease(input)
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
