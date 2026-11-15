import DeskhandCore
import DeskhandPlatform
import Foundation

enum ProcessStop {
    static func install(executor: InputExecutor, host: any CleanStopHost) -> TerminationSignal {
        let stop = CleanStop(executor: executor, host: host, exit: { Foundation.exit($0) })
        return TerminationSignal {

            let signalled = ContinuousClock.now
            Task { await stop.stop(signalledAt: signalled) }
        }
    }
}
