/// The operation a process stop ended (contract 15.2 step 3).
public struct StoppedOperation: Hashable, Sendable {
    public let key: OperationKey
    /// ``ActionOutcome/failedBeforeExecution`` for a call admitted but not yet executing,
    /// ``ActionOutcome/abortedByRestart(eventsPosted:)`` with the exact count for one executing.
    public let outcome: ActionOutcome
    /// The record reached the disk with this outcome. When it did not, the next start applies the
    /// restart rules to what did, with the last count on disk as a lower bound (contract 12.9).
    public let recorded: Bool

    public init(key: OperationKey, outcome: ActionOutcome, recorded: Bool) {
        self.key = key
        self.outcome = outcome
        self.recorded = recorded
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

/// What a stop waits for.
enum StopMilestone: Sendable {
    /// No call is in the admission section: the stopped operation's releases are done and its
    /// record is written.
    case sectionLeft
    /// No call is left to answer and no refusal entry is held back: every action log entry of a
    /// call the stop ended was written, or its append gave up.
    case entriesSettled
}

struct StopWaiter {
    let milestone: StopMilestone
    let continuation: CheckedContinuation<Void, Never>
}

extension InputExecutor {
    /// ``beginStop()`` was called: every call is dropped from now on (contract 15.2 step 1).
    public var isStopping: Bool { stopRequested }

    /// Marks deskhand as stopping, and returns at once: every call is dropped with no answer from
    /// now on, and the call in the admission section ends at its next check, before its next event
    /// or within one activity poll while it waits. Call it before the listener stops taking calls,
    /// so that an effect whose connection the listener then closes still ends as the stop's, not
    /// as `cancelled` (contract 15.2).
    public func beginStop() {
        stopRequested = true
    }

    /// The executor's part of a process stop (contract 15.2 steps 2 and 3), after ``beginStop()``,
    /// which it implies. An admitted call that had not started executing ends
    /// `failed_before_execution`; an executing one releases what it holds, if cleanup is
    /// authorized, and ends `aborted_by_restart` with the exact count. Either way its record is
    /// written durably before this returns. Releases still owed from earlier operations are then
    /// posted, if cleanup is authorized; otherwise they stay in the ledger.
    ///
    /// Returns once no call is in the admission section, without waiting for the action log:
    /// ``awaitStopEntries()`` waits for that. A call still before admission can wait on the action
    /// log, the frame check or the patch recapture for up to ``Configuration/waitLimit``, so the
    /// caller bounds the wait by the stop's own deadline. Calling it again waits the same way and
    /// returns the same operation.
    public func stop() async -> ExecutorStop {
        beginStop()
        await reach(.sectionLeft)
        _ = releaseOwedInput()
        return ExecutorStop(operation: stoppedOperation, heldInput: ledger.pending())
    }

    /// Step 4's action log entries, after ``stop()``: returns once the stopped operation's outcome
    /// entry and every refusal entry held back for an intent append that had not returned
    /// (``PendingIntent``) were written or given up. A held refusal entry is written once that
    /// append returns, after its intent, never by the stop itself. Each append is bounded by
    /// ``Configuration/waitLimit``, so the caller bounds this by the stop's own deadline.
    ///
    /// Whether the stopped operation's outcome entry was committed (contract 12.10); `nil` when the
    /// stop ended no operation.
    public func awaitStopEntries() async -> Bool? {
        await reach(.entriesSettled)
        return stoppedOperation.map { _ in stoppedOutcomeLogged }
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
        stoppedOperation = StoppedOperation(key: execution.call.key, outcome: outcome, recorded: recorded)
        leaveSection()
        let measured: Measured? =
            switch outcome {
            case .failedBeforeExecution: nil
            default: execution.lastLookMeasured ?? execution.admissionMeasured
            }
        let log = seams.log
        let receipt = execution.receipt
        let now = seams.state.snapshot().reading.wall
        stoppedOutcomeLogged =
            await logAppend { () async -> Void? in
                do throws(ActionLogFailure) {
                    return try await log.commitOutcome(receipt, outcome, measured: measured, now: now)
                } catch {
                    return nil
                }
            } != nil
        return .dropped
    }

    /// Resumes the stops waiting for a milestone that has now been reached.
    func resumeStopWaiters() {
        guard !stopWaiters.isEmpty else { return }
        var waiting: [StopWaiter] = []
        for waiter in stopWaiters {
            if hasReached(waiter.milestone) { waiter.continuation.resume() } else { waiting.append(waiter) }
        }
        stopWaiters = waiting
    }

    private func reach(_ milestone: StopMilestone) async {
        guard !hasReached(milestone) else { return }
        await withCheckedContinuation { stopWaiters.append(StopWaiter(milestone: milestone, continuation: $0)) }
    }

    private func hasReached(_ milestone: StopMilestone) -> Bool {
        switch milestone {
        case .sectionLeft: section.isIdle
        case .entriesSettled: callsAnswering == 0 && refusalsHeld == 0
        }
    }
}
