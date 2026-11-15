import DeskhandTestSupport
import Testing

@testable import DeskhandCore

@Suite("Executor: bounded waits and the order of append reports", .timeLimit(.minutes(1)))
struct BoundedWaitTests {
    struct Report: Sendable, CustomTestStringConvertible {
        let attempt: Int
        let answered: Bool
        let decides: Bool

        var testDescription: String { "\(attempt) \(answered ? "answered" : "ran out") -> \(decides)" }
    }

    static let orders: [[Report]] = [
        [Report(attempt: 1, answered: true, decides: true), Report(attempt: 1, answered: false, decides: false)],
        [Report(attempt: 1, answered: false, decides: true), Report(attempt: 1, answered: true, decides: true)],
        [Report(attempt: 2, answered: true, decides: true), Report(attempt: 1, answered: false, decides: false)],
        [Report(attempt: 2, answered: false, decides: true), Report(attempt: 1, answered: true, decides: false)],
        [Report(attempt: 1, answered: true, decides: true), Report(attempt: 2, answered: false, decides: true)],
        [
            Report(attempt: 2, answered: false, decides: true), Report(attempt: 1, answered: true, decides: false),
            Report(attempt: 2, answered: true, decides: true), Report(attempt: 2, answered: false, decides: false),
        ],
    ]

    @Test(
        "the most recent attempt decides log_unavailable, and a timeout never replaces its own answer",
        arguments: orders)
    func reportOrder(reports: [Report]) {
        var attempts = ActionLogAttempts()
        for _ in 0..<(reports.map(\.attempt).max() ?? 0) { _ = attempts.start() }
        for report in reports {
            #expect(attempts.decides(report.attempt, answered: report.answered) == report.decides, "\(report)")
        }
    }

    @Test("a wait answers with the operation's value, and nil only once its limit passed; a late value goes on")
    func boundedWait() async {
        let limits = ManualWaitLimits()
        let limit = WaitLimit(duration: .seconds(3600), timer: limits)
        #expect(await awaitBounded(within: limit, { 7 }) == 7)

        let gate = Gate()
        let late = Box<Int>()
        let delivered = Waiters()
        let held: @Sendable () async -> Int = {
            await gate.pass()
            return 9
        }
        let waiting = Task {
            await awaitBounded(within: limit, held) { value in
                late.set(value)
                delivered.changed()
            }
        }
        var arrivals = gate.arrived.makeAsyncIterator()
        _ = await arrivals.next()
        let answer = await limits.passing { await finished(waiting) }
        #expect(answer == .some(nil), "the wait did not end when its limit passed")
        #expect(late.value == nil)

        await gate.open()
        await delivered.wait { late.value != nil }
        #expect(late.value == 9)
    }
}
