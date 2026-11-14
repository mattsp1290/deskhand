/// The operation a process stop ended (contract 15.2 step 3).
public struct StoppedOperation: Hashable, Sendable {
    public let key: OperationKey
    /// ``ActionOutcome/failedBeforeExecution`` for a call admitted but not yet executing,
    /// ``ActionOutcome/abortedByRestart(eventsPosted:)`` with the exact count for one executing.
    public let outcome: ActionOutcome
    /// The record reached the disk with this outcome. When it did not, the next start applies the
    /// restart rules to what did, with the last count on disk as a lower bound (contract 12.9).
    public let recorded: Bool
    /// The outcome entry was committed to the action log (contract 12.10).
    public let logged: Bool

    public init(key: OperationKey, outcome: ActionOutcome, recorded: Bool, logged: Bool) {
        self.key = key
        self.outcome = outcome
        self.recorded = recorded
        self.logged = logged
    }
}

/// What ``InputExecutor/stop()`` did (contract 15.2 steps 2 to 4).
public struct ExecutorStop: Hashable, Sendable {
    /// `nil` when no call had been admitted: the section was empty, or its call was still before
    /// admission and was dropped with no record.
    public let operation: StoppedOperation?
    /// What the ledger still holds, newest last: releases that were not authorized, or could not
    /// be posted. The next start reports `cleanup_pending` and posts them once cleanup is
    /// authorized (contract 12.9 step 5).
    public let heldInput: [HeldInput]

    public init(operation: StoppedOperation?, heldInput: [HeldInput]) {
        self.operation = operation
        self.heldInput = heldInput
    }
}

extension InputExecutor {
    /// ``stop()`` was called: every call is dropped from now on (contract 15.2 step 1).
    public var isStopping: Bool { stopRequested }

    /// The executor's part of a process stop (contract 15.2): after this is called every call is
    /// dropped with no answer, and the call in the admission section ends at its next check, before
    /// its next event or within one activity poll while it waits. An admitted call that had not
    /// started executing ends `failed_before_execution`; an executing one releases what it holds,
    /// if cleanup is authorized, and ends `aborted_by_restart` with the exact count. Either way the
    /// record is written durably and the outcome entry is committed before this returns. Releases
    /// still owed from earlier operations are then posted, if cleanup is authorized; otherwise they
    /// stay in the ledger.
    ///
    /// Returns once no call is left to answer. A call still before admission can wait on the action
    /// log, the frame check or the patch recapture for up to ``Configuration/waitLimit``, so the
    /// caller bounds the wait by the stop's own deadline. Calling it again waits the same way and
    /// returns the same operation.
    public func stop() async -> ExecutorStop {
        stopRequested = true
        if callsAnswering > 0 { await withCheckedContinuation { stopWaiters.append($0) } }
        _ = releaseOwedInput()
        return ExecutorStop(operation: stoppedOperation, heldInput: ledger.pending())
    }

    /// Ends an admitted call because deskhand is stopping: the releases it owes, its record through
    /// ``OperationStore/interrupt(_:eventsPosted:)``, and its outcome entry. The caller gets no
    /// answer: it sees the connection close.
    func endStopped(_ execution: Execution, _ outcome: ActionOutcome) async -> EffectAnswer {
        if !execution.pressed.isEmpty { releaseOperationInput(execution.pressed) }
        var recorded = false
        if let store {
            do throws(OperationStoreError) {
                try store.interrupt(execution.ticket, eventsPosted: execution.eventsPosted)
                recorded = true
            } catch {
                // As for a final write the store refused while still available (``end(_:_:)``).
                if store.isAvailable { self.store = nil }
            }
        }
        leaveSection()
        let measured: Measured? =
            switch outcome {
            case .failedBeforeExecution: nil
            default: execution.lastLookMeasured ?? execution.admissionMeasured
            }
        let log = seams.log
        let receipt = execution.receipt
        let now = seams.state.snapshot().reading.wall
        let logged = await logAppend {
            do throws(ActionLogFailure) {
                try await log.commitOutcome(receipt, outcome, measured: measured, now: now)
                return true
            } catch {
                return false
            }
        }
        stoppedOperation = StoppedOperation(
            key: execution.call.key, outcome: outcome, recorded: recorded, logged: logged)
        return .dropped
    }

    func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
