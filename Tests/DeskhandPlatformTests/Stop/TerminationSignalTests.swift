import Darwin
import DeskhandPlatform
import DeskhandTestSupport
import Testing

@Suite("Stop: the termination signal", .serialized, .timeLimit(.minutes(1)))
struct TerminationSignalTests {

    static func deliver(_ number: Int32, count: Int) async {
        let (runs, handled) = AsyncStream<Void>.makeStream()
        let signal = TerminationSignal(signal: number) { handled.yield() }
        defer { signal.cancel() }
        var iterator = runs.makeAsyncIterator()
        for _ in 0..<count {
            kill(getpid(), number)
            _ = await iterator.next()
        }
    }

    @Test("SIGUSR2 runs the handler, again on a second delivery, and the process lives on")
    func userSignal() async {
        await Self.deliver(SIGUSR2, count: 2)
    }

    @Test("a signal sent as soon as the source is installed is never lost", .timeLimit(.minutes(1)))
    func signalAtInstall() async {
        for _ in 0..<200 { await Self.deliver(SIGUSR2, count: 1) }
    }

    @Test(
        "SIGTERM runs the handler, again on a second delivery, and the process lives on",
        .tags(.requiresMacSession), .macSessionTestsEnabled)
    func termination() async {
        await Self.deliver(SIGTERM, count: 2)
    }
}
