import Darwin
import Dispatch

/// A signal as an event rather than as its default action: `SIGTERM`, which launchd sends when it
/// unloads the LaunchAgent, then starts the clean stop instead of ending the process at once
/// (contract 15.2). Every delivery runs `handler` on `queue`, a second `SIGTERM` included; the
/// handler decides what a repeat means.
///
/// One per signal per process. ``cancel()`` restores the default action.
public final class TerminationSignal: @unchecked Sendable {
    // A dispatch source is safe to use from any thread; the SDK does not mark it Sendable.
    private let source: any DispatchSourceSignal
    public let number: Int32

    public init(
        signal number: Int32 = SIGTERM, queue: DispatchQueue = DispatchQueue(label: "deskhand.termination-signal"),
        handler: @escaping @Sendable () -> Void
    ) {
        self.number = number
        // The source observes the signal through kqueue, which still sees it while its action is
        // "ignore"; without this the default action would end the process first.
        Darwin.signal(number, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
    }

    /// Stops observing the signal and restores its default action.
    public func cancel() {
        source.cancel()
        Darwin.signal(number, SIG_DFL)
    }
}
