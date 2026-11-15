import DeskhandCore
import Synchronization
import Testing

@Suite("Executor: aborts after every event", .timeLimit(.minutes(1)))
struct AbortSweepTests {
    enum Cause: String, CaseIterable, Sendable { case userActive, paused, hangUp, postFails, locked }

    static let actions: [JSONValue] = [
        ["type": "press", "key": "k", "modifiers": ["shift", "control", "command"], "hold_ms": 120],
        ["type": "type", "text": "abc"],
        ["type": "click", "x": 30, "y": 30, "count": 3, "modifiers": ["option", "shift"]],
        ["type": "drag", "path": [["x": 3, "y": 3], ["x": 40, "y": 9]], "duration_ms": 60, "modifiers": ["shift"]],
        ["type": "scroll", "x": 9, "y": 9, "dy": 300, "modifiers": ["command"]],
    ]

    static func call(_ action: JSONValue, on harness: Harness, connection: any ConnectionLiveness) throws -> EffectCall
    {
        action["type"] == "press" || action["type"] == "type"
            ? try harness.keyboard(action, connection: connection)
            : try harness.pointer(action, connection: connection)
    }

    @Test("an abort after any event leaves nothing down and nothing owed", arguments: Cause.allCases)
    func abortSweep(_ cause: Cause) async throws {
        for action in Self.actions {
            let whole = try Harness()
            let total = try #require(
                await whole.executor.perform(try Self.call(action, on: whole, connection: FakeConnection())).result?
                    .eventsPosted)
            for n in 0...total {
                let mac = FakeMac { world in
                    switch cause {
                    case .userActive: world.afterPost[n] = { world, _ in world.idleMs = 0 }
                    case .paused:
                        world.afterPost[n] = { world, now in world.report = ExecutorFixture.report([.paused], at: now) }
                    case .locked:
                        world.afterPost[n] = { world, now in world.report = ExecutorFixture.report([.locked], at: now) }
                    case .hangUp: break
                    case .postFails: world.failPostAt = n + 1
                    }
                }
                let harness = try Harness(mac: mac)
                let connection = FakeConnection(openReads: cause == .hangUp ? 2 + n : .max)
                let answer = await harness.executor.perform(try Self.call(action, on: harness, connection: connection))
                if n == 0, cause != .hangUp, cause != .postFails { continue }
                let label = "\(cause) after event \(n) of \(action["type"]!)"
                if n < total {
                    #expect(answer.result == nil, "\(label): completed")
                    if cause == .hangUp {
                        #expect((answer.operation?.eventsPosted ?? .max) <= n, "\(label)")
                    } else if cause != .postFails {
                        #expect(answer.operation?.eventsPosted == n, "\(label)")
                    }
                }
                var down: [HeldInput] = []
                var releases: [HeldInput] = []
                var downAtAbort: [HeldInput]?
                for entry in mac.read(\.trace) {
                    switch entry {
                    case .posted(let event):
                        if let input = event.press, !down.contains(input) { down.append(input) }
                        if let input = event.release { down.removeAll { $0 == input } }
                    case .released(let input):
                        if downAtAbort == nil { downAtAbort = down }
                        releases.append(input)
                        down.removeAll { $0 == input }
                    case .ledger: break
                    }
                }
                if cause == .locked, n < total {
                    #expect(releases.isEmpty, "\(label): released while locked")
                    #expect(
                        Set(mac.ledgerOnDisk).isSuperset(of: down), "\(label): ledger \(mac.ledgerOnDisk) lacks \(down)"
                    )
                    #expect(await harness.executor.owesReleases == !mac.ledgerOnDisk.isEmpty)
                    continue
                }
                #expect(down.isEmpty, "\(label): still down \(down)")
                #expect(mac.ledgerOnDisk.isEmpty, "\(label): ledger \(mac.ledgerOnDisk)")
                if let downAtAbort {
                    let releasedDown = releases.filter { downAtAbort.contains($0) }
                    #expect(
                        releasedDown == downAtAbort.reversed().filter { releases.contains($0) },
                        "\(label): order \(releases) for \(downAtAbort)")
                }
                #expect(await harness.executor.isInSection == false)
            }
        }
    }

    @Test("cleanup and a reload during an operation touch nothing it holds")
    func cleanupDuringOperation() async throws {
        let mac = FakeMac()
        let harness = try Harness(mac: mac)
        let executor = harness.executor
        let seen = Mutex<[String]>([])
        mac.change {
            $0.onSleep = {
                let owed = await executor.releaseOwedInput()
                let retried = await executor.retryCleanup(now: mac.reading)
                _ = await executor.reloadUnavailableStores()
                let label: String
                switch (owed, retried) {
                case (.operationInSection, .operationInSection?): label = "operationInSection"
                default: label = "touched"
                }
                seen.withLock { $0.append("\(label) released=\(mac.released.count) owes=\(mac.ledgerOnDisk.count)") }
            }
        }
        let answer = await executor.perform(
            try harness.keyboard(["type": "press", "key": "k", "modifiers": ["shift"], "hold_ms": 250]))
        #expect(answer.result?.eventsPosted == 4)
        let all = seen.withLock { $0 }
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { $0 == "operationInSection released=0 owes=2" }, "\(all)")
        #expect(mac.released.isEmpty)
    }
}
