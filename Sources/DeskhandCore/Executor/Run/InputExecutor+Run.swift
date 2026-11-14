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
    /// `press`: the key and the code step 2 resolved it to under the layout then active. A layout
    /// switched since would post a key other than the one named and checked against the denied
    /// shortcuts (contract 6.5), so every check before a down event resolves it again.
    let pressedKey: (key: Key, code: PostedKeyCode)?
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
        pressedKey = Self.pressedKey(of: call.arguments, plan: plan)
    }

    private static func pressedKey(of arguments: EffectCallArguments, plan: ActionPlan) -> (Key, PostedKeyCode)? {
        guard case .keyboard(let keyboard) = arguments, case .press(let press) = keyboard.action else { return nil }
        for planned in plan.events {
            if case .keyDown(let code, text: nil) = planned.event { return (press.key, code) }
        }
        return nil
    }

    var hasStarted: Bool { lastLookMeasured != nil }

    var claim: SectionClaim { SectionClaim(key: call.key, digest: call.digest) }
}

/// What one check before an event, or at a poll while input is held, found.
private struct Look {
    /// The first cause in the order of contract 9.5, or `nil` when the event may be posted.
    let stop: ToolErrorReason?
    /// The layout no longer gives the pressed key the code it was resolved to: a fault.
    let layoutChanged: Bool
    /// ``AppCheck/pointOwner`` as the policy decides on it.
    let pointOwner: AppIdentity?

    var ending: Ending? {
        if let stop { return .stopped(stop) }
        return layoutChanged ? .fault("The keyboard layout changed after the key was resolved.") : nil
    }
}

/// How an executing operation ends (contract 12.2, 12.4).
enum Ending: Sendable {
    case completed
    /// An abort with the code of its cause: `aborted`.
    case stopped(ToolErrorReason)
    /// A fault inside deskhand: `failed` with `internal_error`.
    case fault(String)
    /// deskhand is stopping (contract 15.2): `aborted_by_restart` with the exact count.
    case processStop
}

extension InputExecutor {
    /// A hold polls once per `USER_ACTIVITY_POLL_MS`, once more to end, and once per move of the
    /// deadline. These many polls beyond what its length needs, at each of which the clock read no
    /// later than at the one before, mean the clock it is timed by does not advance, and the hold
    /// ends as a fault about `DEADLINE_BOUND_MS` after it was due. A poll at which the clock did
    /// advance is not counted, so a timer that returns early only polls more often.
    public static let holdPollSlack = ContractConstants.deadlineBoundMs / ContractConstants.userActivityPollMs

    /// Contract 12.3 steps 4 to 9 for an admitted call.
    func execute(_ admitted: Execution) async -> EffectAnswer {
        var execution = admitted
        if stopRequested { return await endStopped(execution, .failedBeforeExecution) }
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
        if stopRequested { return .processStop }
        var press: PressEntry?
        if let input = planned.event.press {
            do throws(HeldInputLedgerError) {
                press = try ledger.willPress(input)
            } catch {
                return .fault("The held-input ledger could not be written.")
            }
            if press?.isNew == true { execution.pressed.append(input) }
        }
        let look = look(at: planned.target, beforeDown: planned.event.press != nil, &execution)
        if let ending = look.ending {
            if let press, press.isNew {
                try? ledger.withdraw(press)
                if !ledger.pending().contains(press.input) { execution.pressed.removeAll { $0 == press.input } }
            }
            return ending
        }
        do {
            try seams.poster.post(planned.event)
        } catch {
            return .fault("An input event could not be posted.")
        }
        // Read after the post: a hold, `completed_at` and the arming lookback run from the event,
        // not from the checks before it (contract 6.4, 6.5, 6.7, 10.4).
        let posted = seams.state.snapshot().reading
        execution.eventsPosted += 1
        section = .executing(execution.claim, execution.ticket, eventsPosted: execution.eventsPosted)
        execution.lastPostedAt = posted.wall
        seams.observer.didPostEvent(at: posted.monotonic)
        if planned.startsHold { execution.holdAnchor = posted.monotonic }
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

    /// The checks before an event and at every poll while input is held (contract 12.3 steps 5 and
    /// 6, 12.4, 13), stopping at the first cause in the order of contract 9.5.
    ///
    /// The first of them is the last look, which also takes the facts `measured` reports, even
    /// when a check fails, and binds the identities the rest of the operation must keep; a later
    /// one follows a frontmost switch the binding accepted.
    ///
    /// The identities, and before a down event the key's code, are read first, because those reads
    /// can wait on a busy app. The state, the lease and its deadline, the person at the Mac, the
    /// connection and the watchdog's interruptions are read after them, so nothing slow lies
    /// between those reads and the post: a kill switch used during an identity read stops the
    /// event (contract 12.3 step 5, 13.3).
    private func look(at target: CheckTarget, beforeDown: Bool, _ execution: inout Execution) -> Look {
        let isLastLook = !execution.hasStarted
        let check = AppCheck.run(
            isLastLook ? .lastLook : .event(target), action: execution.action,
            permittedApps: execution.call.arguments.permittedApps, binding: isLastLook ? nil : execution.binding,
            snapshot: seams.state.snapshot(), identity: seams.identity)
        if isLastLook { execution.lastLookMeasured = check.measured ?? execution.admissionMeasured }
        var layoutChanged = false
        if beforeDown, let pressed = execution.pressedKey {
            layoutChanged = seams.keyCodes.code(for: pressed.key) != pressed.code
        }

        let snapshot = seams.state.snapshot()
        var stop = standingCause(of: execution, snapshot)
        if stop == nil, isLastLook, let checkedAt = execution.patchCheckedAt,
            checkedAt.duration(to: snapshot.reading.monotonic) > .milliseconds(ContractConstants.patchCheckMaxAgeMs)
        {
            stop = .staleFrame(.pixelsChanged(pointIndex: 0))
        }
        if stop == nil { stop = check.denial }
        if stop == nil, !execution.call.connection.isOpen { stop = .cancelled }
        stop = .first(stop, interruptions.cause(under: execution.lease))
        if stop == nil {
            if isLastLook {
                execution.binding = check.binding
            } else {
                execution.binding?.follow(frontmost: check.frontmost.policyIdentity)
            }
        }
        return Look(stop: stop, layoutChanged: layoutChanged, pointOwner: check.pointOwner?.policyIdentity)
    }

    /// The state, the lease and the person at the Mac. The deadline is in the first two: the
    /// report applies arming's end and the allowance's expiry with the clock, and the lease check
    /// its expiry (contract 13.1).
    private func standingCause(of execution: Execution, _ snapshot: DeskSnapshot) -> ToolErrorReason? {
        if let blocking = snapshot.state.blocking { return .blocked(blocking) }
        if let ended = snapshot.lease.endCause(of: execution.lease, now: snapshot.reading) { return ended.abortReason }
        return activityCause()
    }

    /// Waits with input held until `elapsed` after the hold's anchor, checking at least every
    /// `USER_ACTIVITY_POLL_MS` and waking for the deadline (contract 13.1, 13.2).
    private func hold(until elapsed: Duration, checking target: CheckTarget, _ execution: inout Execution) async
        -> Ending?
    {
        guard let anchor = execution.holdAnchor else { return nil }
        let end = anchor.advanced(by: elapsed)
        let poll = Duration.milliseconds(ContractConstants.userActivityPollMs)
        let maxStalledPolls = Int((elapsed / poll).rounded(.up)) + Self.holdPollSlack
        var stalledPolls = 0
        var previous = anchor
        while true {
            let snapshot = seams.state.snapshot()
            let now = snapshot.reading.monotonic
            guard now < end else { return nil }
            if now <= previous {
                guard stalledPolls < maxStalledPolls else {
                    return .fault("The clock did not advance while input was held.")
                }
                stalledPolls += 1
            }
            previous = now
            var wait = min(now.duration(to: end), poll)
            let deadline = snapshot.report.effectDeadline(
                of: execution.lease, leases: snapshot.lease, at: snapshot.reading)
            if deadline > now { wait = min(wait, now.duration(to: deadline)) }
            await seams.timer.sleep(for: wait)
            if stopRequested { return .processStop }
            if let ending = look(at: target, beforeDown: false, &execution).ending { return ending }
        }
    }

    /// Contract 12.4 steps 2 to 5, or 12.3 steps 7 to 9 for a completed operation: releases, the
    /// final record, leaving the section, the outcome entry and the answer.
    ///
    /// Every admitted call gets its outcome entry, also when its final record could not be
    /// written: the entry then says `failed` with the count posted, which is what the caller is
    /// answered, so the action log never holds an intent of posted input with no outcome.
    private func end(_ execution: inout Execution, _ ending: Ending) async -> EffectAnswer {
        if case .processStop = ending {
            return await endStopped(execution, .abortedByRestart(eventsPosted: execution.eventsPosted))
        }
        releaseOperationInput(execution.pressed)
        let snapshot = seams.state.snapshot()
        let measured = execution.lastLookMeasured ?? execution.admissionMeasured
        let outcome = self.outcome(of: ending, execution, measured: measured, state: snapshot.state)
        let recorded = finishRecord(execution, outcome)
        leaveSection()
        let logged =
            recorded.flatMap { ActionOutcome($0, eventsPosted: execution.eventsPosted) }
            ?? .failed(eventsPosted: execution.eventsPosted)
        let log = seams.log
        let receipt = execution.receipt
        let loggedMeasured = (recorded ?? outcome).measured
        let now = seams.state.snapshot().reading.wall
        await logAppend { () async -> Void? in
            do throws(ActionLogFailure) {
                return try await log.commitOutcome(receipt, logged, measured: loggedMeasured, now: now)
            } catch {
                return nil
            }
        }
        guard let recorded else {
            let view = OperationView(status: .failed, eventsPosted: execution.eventsPosted)
            return .error(
                ToolError(
                    .internalError, message: "The operation's final record could not be written.",
                    state: snapshot.state, operationID: execution.call.arguments.operationID,
                    operation: .result(view), measured: measured))
        }
        switch recorded {
        case .completed(let result): return .completed(result)
        case .aborted(let error, _), .failed(let error, _): return .error(error)
        }
    }

    /// Contract 12.3 step 7: the final record, or `nil` when it could not be written.
    ///
    /// A store that refused the write without marking itself unavailable (a result it cannot
    /// encode, which a second attempt with the same `measured` would refuse the same way) is
    /// dropped. Every effect is then refused with `internal_error` until it is loaded again, and the
    /// load applies the restart rules, so the record does not stay `executing` while the caller was
    /// told `failed`.
    private func finishRecord(_ execution: Execution, _ outcome: OperationOutcome) -> OperationOutcome? {
        guard let store else { return nil }
        do throws(OperationStoreError) {
            return try store.finish(execution.ticket, outcome, eventsPosted: execution.eventsPosted)
        } catch {
            if store.isAvailable { self.store = nil }
            return nil
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
        case .processStop:
            // ``end(_:_:)`` hands a stop to ``endStopped(_:_:)``, which never finishes a record.
            return .failed(
                ToolError(.internalError, message: "deskhand stopped during this operation.", state: state),
                measured: measured)
        }
    }
}
