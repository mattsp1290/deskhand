import Darwin
import Dispatch

/// A signal as an event rather than as its default action: `SIGTERM`, which launchd sends when it
/// unloads the LaunchAgent, then starts the clean stop instead of ending the process at once
/// (contract 15.2). Every delivery runs `handler`, a second `SIGTERM` included; the handler decides
/// what a repeat means.
///
/// One per signal per process. ``cancel()`` restores the default action.
public final class TerminationSignal: @unchecked Sendable {
    // A dispatch source is safe to use from any thread; the SDK does not mark it Sendable.
    private let source: any DispatchSourceSignal
    public let number: Int32

    /// Returns once the signal is observed: from then on no delivery is lost. A delivery before
    /// that takes the default action, as if nothing were installed.
    public init(signal number: Int32 = SIGTERM, handler: @escaping @Sendable () -> Void) {
        self.number = number
        let installed = DispatchSemaphore(value: 0)
        source = DispatchSource.makeSignalSource(
            signal: number, queue: DispatchQueue(label: "deskhand.termination-signal"))
        source.setEventHandler(handler: handler)
        // kqueue counts a signal only once the source is registered, which `resume()` starts but
        // does not finish. Ignored before that, a signal would be neither counted nor acted on.
        source.setRegistrationHandler { installed.signal() }
        source.resume()
        installed.wait()
        // The source still sees the signal while its action is "ignore"; without this the default
        // action would end the process first.
        Darwin.signal(number, SIG_IGN)
    }

    /// Restores the signal's default action and stops observing it, in that order, so a delivery in
    /// between is acted on rather than ignored.
    public func cancel() {
        Darwin.signal(number, SIG_DFL)
        source.cancel()
    }
}
