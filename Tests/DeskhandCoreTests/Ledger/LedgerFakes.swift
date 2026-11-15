import DeskhandCore
import Testing

struct LedgerCrash: Error {}

struct LedgerFault: Error {}

extension HeldInput {
    static let control = HeldInput.modifier(PostedKeyCode(0x3B))
    static let shift = HeldInput.modifier(PostedKeyCode(0x38))
    static let command = HeldInput.modifier(PostedKeyCode(0x37))
    static let option = HeldInput.modifier(PostedKeyCode(0x3A))
    static let keyA = HeldInput.key(PostedKeyCode(0x00))
    static let keyT = HeldInput.key(PostedKeyCode(0x11))
    static let returnKey = HeldInput.key(PostedKeyCode(0x24))
}

enum WriteFault: CaseIterable, Sendable, CustomStringConvertible {
    case lost
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

final class LedgerMachine {
    private(set) var disk: [UInt8]?
    private(set) var held: Set<HeldInput> = []
    private(set) var posted: [LedgerEvent] = []
    private(set) var trace: [LedgerBoundary] = []
    private(set) var writes = 0
    private(set) var writeAttempts = 0
    private(set) var crashedAt: LedgerBoundary?
    var crashAt: Int?
    var writeFault: WriteFault?
    var faultAtWrite: (index: Int, fault: WriteFault)?
    var failPosts = false

    init(crashAt: Int? = nil, disk: [UInt8]? = nil) {
        self.crashAt = crashAt
        self.disk = disk
    }

    func overwriteDisk(_ bytes: [UInt8]?) { disk = bytes }

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

enum LedgerScenario: String, CaseIterable, Sendable {
    case chord
    case drag
    case twoOperations
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

    func trace() throws -> [LedgerBoundary] {
        let machine = LedgerMachine()
        var ledger = try HeldInputLedger(store: machine.store)
        try run(&ledger, on: machine)
        return machine.trace
    }
}
