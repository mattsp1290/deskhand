struct Execution: Sendable {
    let call: EffectCall
    let ticket: OperationTicket
    let receipt: IntentReceipt
    let plan: ActionPlan
    let action: CheckedAction
    let lease: Lease
    let patchCheckedAt: ContinuousClock.Instant?
    let admissionMeasured: Measured
    let pressedKey: (key: Key, code: PostedKeyCode)?
    var lastLookMeasured: Measured?
    var binding: IdentityBinding?
    var eventsPosted = 0
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

private struct Look {
    let stop: ToolErrorReason?
    let layoutChanged: Bool
    let pointOwner: AppIdentity?

    var ending: Ending? {
        if let stop { return .stopped(stop) }
        return layoutChanged ? .fault("The keyboard layout changed after the key was resolved.") : nil
    }
}

enum Ending: Sendable {
    case completed
    case stopped(ToolErrorReason)
    case fault(String)
}

extension InputExecutor {
    /// A hold polls once per `USER_ACTIVITY_POLL_MS`, once more to end, and once per move of the
    /// deadline. These many polls beyond what its length needs, at each of which the clock read no
    /// later than at the one before, mean the clock it is timed by does not advance, and the hold
    /// ends as a fault about `DEADLINE_BOUND_MS` after it was due. A poll at which the clock did
    /// advance is not counted, so a timer that returns early only polls more often.
    public static let holdPollSlack = ContractConstants.deadlineBoundMs / ContractConstants.userActivityPollMs

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

    private func standingCause(of execution: Execution, _ snapshot: DeskSnapshot) -> ToolErrorReason? {
        if let blocking = snapshot.state.blocking { return .blocked(blocking) }
        if let ended = snapshot.lease.endCause(of: execution.lease, now: snapshot.reading) { return ended.abortReason }
        return activityCause()
    }

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
            if let ending = look(at: target, beforeDown: false, &execution).ending { return ending }
        }
    }

    private func end(_ execution: inout Execution, _ ending: Ending) async -> EffectAnswer {
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
        }
    }
}
