import DeskhandCore
import DeskhandPlatform
import Foundation

/// `SIGTERM` wired to the clean stop (contract 15.2). The app's assembly calls
/// ``install(executor:host:)`` once, after the executor and the listener exist, and keeps the
/// result for the life of the process. The stop itself is ``CleanStop``; this only connects the
/// signal and the process exit.
enum ProcessStop {
    static func install(executor: InputExecutor, host: any CleanStopHost) -> TerminationSignal {
        let stop = CleanStop(executor: executor, host: host, exit: { Foundation.exit($0) })
        return TerminationSignal {
            // Read where the signal is handled, so the bound runs from the signal, not from the
            // task that starts the stop.
            let signalled = ContinuousClock.now
            Task { await stop.stop(signalledAt: signalled) }
        }
    }
}
