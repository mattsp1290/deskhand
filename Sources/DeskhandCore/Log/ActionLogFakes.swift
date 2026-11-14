/// An action log held in memory, for tests. Like the writer daemon, it accepts a line only when it
/// decodes to an entry and is spelled canonically.
public actor InMemoryActionLog: ActionLogClient {
    public private(set) var lines: [ActionLogLine] = []

    public init() {}

    public var entries: [ActionLogEntry] { lines.map(\.entry) }

    public func append(_ line: ActionLogLine) async throws(ActionLogFailure) {
        guard (try? ActionLogLine(verifying: line.bytes)) == line else { throw .notCommitted }
        lines.append(line)
    }
}

/// Wraps another client and makes appends fail on demand, for tests of `log_unavailable`.
public actor FaultInjectingActionLog<Base: ActionLogClient>: ActionLogClient {
    public enum Fault: Hashable, Sendable {
        /// The line is not passed on, and the append throws.
        case reject(ActionLogFailure)
        /// The line is passed on and committed, but the acknowledgement is lost, so the append throws.
        case lostAcknowledgement(ActionLogFailure)
    }

    public let base: Base
    /// Every line offered, whether or not it failed.
    public private(set) var attempts: [ActionLogLine] = []
    private var queued: [ActionLogEntryKind: [Fault]] = [:]
    private var standing: [ActionLogEntryKind: Fault] = [:]

    public init(wrapping base: Base) { self.base = base }

    /// Fails the next append of `kind` only. Queued faults run before a standing one.
    public func failNext(_ kind: ActionLogEntryKind, with fault: Fault) {
        queued[kind, default: []].append(fault)
    }

    /// Fails every append of `kind` until cleared with `nil`.
    public func failEvery(_ kind: ActionLogEntryKind, with fault: Fault?) {
        standing[kind] = fault
    }

    public func append(_ line: ActionLogLine) async throws(ActionLogFailure) {
        attempts.append(line)
        let kind = line.entry.kind
        let fault = queued[kind]?.isEmpty == false ? queued[kind]!.removeFirst() : standing[kind]
        switch fault {
        case nil: try await base.append(line)
        case .reject(let failure)?: throw failure
        case .lostAcknowledgement(let failure)?:
            try await base.append(line)
            throw failure
        }
    }
}
