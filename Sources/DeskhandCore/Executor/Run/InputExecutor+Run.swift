/// One admitted operation while it executes.
struct Execution: Sendable {
    let call: EffectCall
    let ticket: OperationTicket
    let receipt: IntentReceipt
    let plan: ActionPlan
    let action: CheckedAction
    /// The live lease the call was admitted under. Any other lease, even the same holder's after a
    /// release and an `acquire`, ends the operation (contract 5.3).
    let lease: Lease
    /// When the patch recapture began, for the 250 ms bound at the first event (contract 8.4).
    let patchCheckedAt: ContinuousClock.Instant?
    /// Step 14's facts, reported by an operation that ended before its last look (contract 6.7).
    let admissionMeasured: Measured
    var lastLookMeasured: Measured?
    var binding: IdentityBinding?
    var eventsPosted = 0
    /// What this operation put down and has not let up, in press order: all its abort releases.
    var pressed: [HeldInput] = []
    var holdAnchor: ContinuousClock.Instant?
    var lastPostedAt: Timestamp?

    init(
        call: EffectCall, ticket: OperationTicket, receipt: IntentReceipt, plan: ActionPlan, action: CheckedAction,
        lease: Lease, patchCheckedAt: ContinuousClock.Instant?, admissionMeasured: Measured
    ) {
        self.call = call
        self.ticket = ticket
        self.receipt = receipt
        self.plan = plan
        self.action = action
        self.lease = lease
        self.patchCheckedAt = patchCheckedAt
        self.admissionMeasured = admissionMeasured
    }

    var hasStarted: Bool { lastLookMeasured != nil }

    var claim: SectionClaim { SectionClaim(key: call.key, digest: call.digest) }
}

/// What one check before an event, or at a poll while input is held, found.
private struct Look {
    /// The first cause in the order of contract 9.5, or `nil` when the event may be posted.
    let stop: ToolErrorReason?
    let reading: ClockReading
    /// ``AppCheck/pointOwner`` as the policy decides on it, when the app check ran.
    let pointOwner: AppIdentity?
}

/// How an executing operation ends (contract 12.2, 12.4).
enum Ending: Sendable {
    case completed
    /// An abort with the code of its cause: `aborted`.
    case stopped(ToolErrorReason)
    /// A fault inside deskhand: `failed` with `internal_error`.
    case fault(String)
}

extension InputExecutor {
    /// Contract 12.3 steps 4 to 9 for an admitted call.
    func execute(_ admitted: Execution) async -> EffectAnswer {
        var execution = admitted
        do throws(OperationStoreError) {
            guard let store else { throw .unavailable }
            try store.markExecuting(execution.ticket)
        } catch {
            return await end(&execution, .fault("The operation record could not be written."))
        }
        section = .executing(execution.claim, execution.ticket, eventsPosted: 0)
        seams.observer.executionDidChange(executing: true)
        for step in execution.plan.steps {
            let ending: Ending?
            switch step {
            case .post(let planned): ending = await post(planned, &execution)
            case .hold(let elapsed, let target): ending = await hold(until: elapsed, checking: target, &execution)
            }
            if let ending { return await end(&execution, ending) }
        }
        return await end(&execution, .completed)
    }

    /// One event in the fixed order of contract 12.3 step 6: the ledger entry of a down event, the
    /// checks, the post, and the clear of an up event's entry.
    private func post(_ planned: PlannedEvent, _ execution: inout Execution) async -> Ending? {
        var press: PressEntry?
        if let input = planned.event.press {
            do throws(HeldInputLedgerError) {
                press = try ledger.willPress(input)
            } catch {
                return .fault("The held-input ledger could not be written.")
            }
            if press?.isNew == true { execution.pressed.append(input) }
        }
        let look = execution.hasStarted ? check(planned.target, &execution) : lastLook(&execution)
        if let stop = look.stop {
            if let press, press.isNew {
                try? ledger.withdraw(press)
                if !ledger.pending().contains(press.input) { execution.pressed.removeAll { $0 == press.input } }
            }
            return .stopped(stop)
        }
        do {
            try seams.poster.post(planned.event)
        } catch {
            return .fault("An input event could not be posted.")
        }
        execution.eventsPosted += 1
        section = .executing(execution.claim, execution.ticket, eventsPosted: execution.eventsPosted)
        execution.lastPostedAt = look.reading.wall
        seams.observer.didPostEvent(at: look.reading.monotonic)
        if planned.startsHold { execution.holdAnchor = look.reading.monotonic }
        if case .buttonDown = planned.event, let owner = look.pointOwner {
            execution.binding?.didPostButtonDown(over: owner)
        }
        if let cleared = planned.clears {
            do throws(HeldInputLedgerError) {
                try ledger.didRelease(cleared)
            } catch {
                return .fault("The held-input ledger could not be written.")
            }
            execution.pressed.removeAll { $0 == cleared }
        }
        await Task.yield()
        return nil
    }

    /// The last look (contract 12.3 step 5): the checks before the first event, which also take the
    /// facts `measured` reports, even when a check fails, and bind the identities the rest of the
    /// operation must keep.
    private func lastLook(_ execution: inout Execution) -> Look {
        let snapshot = seams.state.snapshot()
        let check = AppCheck.run(
            .lastLook, action: execution.action, permittedApps: execution.call.arguments.permittedApps, binding: nil,
            snapshot: snapshot, identity: seams.identity)
        execution.lastLookMeasured = snapshot.policy.redactingTitles(check.measured ?? execution.admissionMeasured)
        var stop = standingCause(of: execution, snapshot)
        if stop == nil, let checkedAt = execution.patchCheckedAt,
            checkedAt.duration(to: snapshot.reading.monotonic) > .milliseconds(ContractConstants.patchCheckMaxAgeMs)
        {
            stop = .staleFrame(.pixelsChanged(pointIndex: 0))
        }
        if stop == nil { stop = check.denial }
        if stop == nil, !execution.call.connection.isOpen { stop = .cancelled }
        stop = Self.first(stop, interruptionCause(for: execution))
        if stop == nil { execution.binding = check.binding }
        return Look(stop: stop, reading: snapshot.reading, pointOwner: check.pointOwner?.policyIdentity)
    }

    /// The checks before every later event and at every poll while input is held (contract 12.3
    /// step 6, 12.4), stopping at the first cause in the order of contract 9.5. A frontmost switch
    /// that the binding accepted is followed from here on.
    private func check(_ target: CheckTarget, _ execution: inout Execution) -> Look {
        let snapshot = seams.state.snapshot()
        var stop = standingCause(of: execution, snapshot)
        var appCheck: AppCheck?
        if stop == nil {
            let check = AppCheck.run(
                .event(target), action: execution.action, permittedApps: execution.call.arguments.permittedApps,
                binding: execution.binding, snapshot: snapshot, identity: seams.identity)
            stop = check.denial
            appCheck = check
        }
        if stop == nil, !execution.call.connection.isOpen { stop = .cancelled }
        stop = Self.first(stop, interruptionCause(for: execution))
        if stop == nil, let appCheck { execution.binding?.follow(frontmost: appCheck.frontmost.policyIdentity) }
        return Look(stop: stop, reading: snapshot.reading, pointOwner: appCheck?.pointOwner?.policyIdentity)
    }

    /// The state, the lease and the person at the Mac. The deadline is in the first two: the
    /// report applies arming's end and the allowance's expiry with the clock, and the lease check
    /// its expiry (contract 13.1).
    private func standingCause(of execution: Execution, _ snapshot: DeskSnapshot) -> ToolErrorReason? {
        if let blocking = snapshot.state.blocking { return .blocked(blocking) }
        if let ended = snapshot.lease.endCause(of: execution.lease, now: snapshot.reading) { return ended.abortReason }
        return activityCause()
    }

    private func interruptionCause(for execution: Execution) -> ToolErrorReason? {
        guard let interruption else { return nil }
        if case .leaseEnded(let end) = interruption, end.lease.serial != execution.lease.serial { return nil }
        return interruption.reason
    }

    private static func first(_ lhs: ToolErrorReason?, _ rhs: ToolErrorReason?) -> ToolErrorReason? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return rhs.abortRank < lhs.abortRank ? rhs : lhs
    }

    /// Waits with input held until `elapsed` after the hold's anchor, checking at least every
    /// `USER_ACTIVITY_POLL_MS` and waking for the deadline (contract 13.1, 13.2).
    private func hold(until elapsed: Duration, checking target: CheckTarget, _ execution: inout Execution) async
        -> Ending?
    {
        guard let anchor = execution.holdAnchor else { return nil }
        let end = anchor.advanced(by: elapsed)
        while true {
            let snapshot = seams.state.snapshot()
            let now = snapshot.reading.monotonic
            guard now < end else { return nil }
            var wait = min(now.duration(to: end), .milliseconds(ContractConstants.userActivityPollMs))
            let deadline = snapshot.report.effectDeadline(
                of: execution.lease, leases: snapshot.lease, at: snapshot.reading)
            if deadline > now { wait = min(wait, now.duration(to: deadline)) }
            await seams.timer.sleep(for: wait)
            if let stop = check(target, &execution).stop { return .stopped(stop) }
        }
    }

    /// Contract 12.4 steps 2 to 5, or 12.3 steps 7 to 9 for a completed operation: releases, the
    /// final record, leaving the section, the outcome entry and the answer.
    private func end(_ execution: inout Execution, _ ending: Ending) async -> EffectAnswer {
        if !execution.pressed.isEmpty {
            let state = seams.state
            _ = seams.releases.release(
                execution.pressed, from: &ledger, poster: seams.poster,
                authorization: { state.snapshot().cleanupAuthorization })
        }
        let snapshot = seams.state.snapshot()
        let measured = execution.lastLookMeasured ?? execution.admissionMeasured
        let outcome = self.outcome(of: ending, execution, measured: measured, state: snapshot.state)
        var recorded: OperationOutcome?
        do throws(OperationStoreError) {
            guard let store else { throw .unavailable }
            recorded = try store.finish(execution.ticket, outcome, eventsPosted: execution.eventsPosted)
        } catch {
            recorded = nil
        }
        leaveSection()
        guard let recorded else {
            let view = OperationView(status: .failed, eventsPosted: execution.eventsPosted)
            return .error(
                ToolError(
                    .internalError, message: "The operation's final record could not be written.",
                    state: snapshot.state, operationID: execution.call.arguments.operationID,
                    operation: .result(view), measured: measured))
        }
        if let logged = ActionOutcome(recorded, eventsPosted: execution.eventsPosted) {
            do {
                try await seams.log.commitOutcome(
                    execution.receipt, logged, measured: recorded.measured, now: seams.state.snapshot().reading.wall)
                seams.observer.actionLogDidAppend(succeeded: true)
            } catch {
                seams.observer.actionLogDidAppend(succeeded: false)
            }
        }
        switch recorded {
        case .completed(let result): return .completed(result)
        case .aborted(let error, _), .failed(let error, _): return .error(error)
        }
    }

    private func outcome(
        of ending: Ending, _ execution: Execution, measured: Measured, state: DeskhandState
    ) -> OperationOutcome {
        switch ending {
        case .completed:
            let success: SuccessMeasured? =
                switch execution.call.arguments {
                case .pointer(let pointer): SuccessMeasured(pointer: measured, action: pointer.action)
                case .keyboard: SuccessMeasured(keyboard: measured)
                }
            guard let success, let completedAt = execution.lastPostedAt else {
                return .failed(
                    ToolError(.internalError, message: "The completed action's facts are incomplete.", state: state),
                    measured: measured)
            }
            return .completed(
                EffectResult(
                    operationID: execution.call.arguments.operationID, frameID: execution.call.arguments.frameID,
                    eventsPosted: execution.eventsPosted, replayed: false, measured: success, completedAt: completedAt))
        case .stopped(let reason):
            return .aborted(
                ToolError(
                    reason, message: ExecutorMessages.message(for: reason),
                    state: reason.reportedState(otherwise: state)),
                measured: measured)
        case .fault(let message):
            return .failed(ToolError(.internalError, message: message, state: state), measured: measured)
        }
    }
}
