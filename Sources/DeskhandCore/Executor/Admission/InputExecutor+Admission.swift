enum AdmissionResult: Sendable {
    case admitted(Execution)
    case replay(OperationReplay, state: DeskhandState)
    case refused(Refusal)
    case dropped(Refusal)
}

extension InputExecutor {
    /// Runs one `pointer` or `keyboard` call from refusal step 1 to its answer (contract 9.5,
    /// 12.3). Call it from the task of the request: a connection that closes before admission drops
    /// the call, and one that closes later aborts it with `cancelled`.
    ///
    /// Once ``beginStop()`` was called every call is ``EffectAnswer/dropped`` at once, as is the
    /// call the stop ends (contract 15.2).
    public func perform(_ call: EffectCall) async -> EffectAnswer {
        guard !stopRequested else { return .dropped }
        let snapshot = seams.state.snapshot()
        if let blocking = snapshot.state.blocking {
            return await refuse(call, Refusal(.blocked(blocking), operation: recordView(call.key, at: snapshot)))
        }
        var keyboardPlan: ActionPlan?
        if case .keyboard(let keyboard) = call.arguments {
            do {
                keyboardPlan = try ActionExpansion.keyboard(keyboard.action, keyCodes: seams.keyCodes)
            } catch {
                let refusal = Refusal(
                    .invalidArgument(error.pointer), message: error.description,
                    operation: recordView(call.key, at: snapshot))
                return await refuse(call, refusal)
            }
        }
        if let held = section.refusal(for: call.key, digest: call.digest) {
            let view = sectionView(of: call.key) ?? recordView(call.key, at: snapshot)
            return await refuse(call, Refusal(held, operation: view))
        }
        guard call.connection.isOpen else {
            await logRefusal(refusalEntry(call, Refusal(.cancelled), at: snapshot))
            return .dropped
        }
        section = .admitting(SectionClaim(key: call.key, digest: call.digest))
        callsAnswering += 1
        let answer = await runSection(call, keyboardPlan: keyboardPlan)
        callsAnswering -= 1
        resumeStopWaiters()
        return answer
    }

    /// From the admission section's start to the call's answer, outcome entry included.
    private func runSection(_ call: EffectCall, keyboardPlan: ActionPlan?) async -> EffectAnswer {
        switch await admit(call, keyboardPlan: keyboardPlan) {
        case .admitted(let execution):
            return await execute(execution)
        case .replay(let replay, let state):
            leaveSection()
            return .replayed(replay, structuredContent: replay.structuredContent(currentState: state))
        case .refused(let refusal):
            leaveSection()
            return await refuse(call, refusal)
        case .dropped(let refusal):
            leaveSection()
            await logRefusal(refusalEntry(call, refusal, at: seams.state.snapshot()))
            return .dropped
        }
    }

    /// The refusal of a call whose arguments did not validate: the state's name while the state is
    /// not `ok`, otherwise `invalid_argument`, each with `operation` when a record exists for the
    /// handles that could be read (contract 9.5 steps 1 and 2). The dispatcher calls this instead of
    /// ``perform(_:)``.
    public func refusal(
        for error: ArgumentError, tool: ToolName, handles: EffectHandles, principal: Principal,
        nodeAddress: NodeAddress
    ) async -> ToolError {
        let snapshot = seams.state.snapshot()
        let reason: ToolErrorReason = snapshot.state.blocking.map { .blocked($0) } ?? .invalidArgument(error.pointer)
        var view: OperationView?
        if let holderID = handles.holderID, let operationID = handles.operationID {
            view = recordView(
                OperationKey(principal: principal, holderID: holderID, operationID: operationID), at: snapshot)
        }
        let toolError = ToolError(
            reason,
            message: reason.code == .invalidArgument ? error.description : ExecutorMessages.message(for: reason),
            state: reason.reportedState(otherwise: snapshot.state), operationID: handles.operationID,
            operation: view.map { .existing($0) })
        await logRefusal(
            ActionLogRefusal(
                time: snapshot.reading.wall, nodeAddress: nodeAddress, principal: principal, tool: tool,
                holderID: handles.holderID, operationID: handles.operationID, frameID: handles.frameID,
                frameSHA256: nil,
                action: nil, frontmostApp: nil, code: toolError.code))
        return toolError
    }

    func admit(_ call: EffectCall, keyboardPlan: ActionPlan?) async -> AdmissionResult {
        var snapshot = seams.state.snapshot()
        let storeFault = Refusal(
            .internalError, message: "The operation records or the held-input ledger are unavailable.")
        guard let store, store.isAvailable, ledger.isAvailable else { return .refused(storeFault) }
        let lookup: OperationLookup
        do {
            lookup = try store.lookup(call.key, digest: call.digest, now: snapshot.reading.wall)
        } catch {
            return .refused(storeFault)
        }
        switch lookup {
        case .absent: break
        case .conflict(let view): return .refused(Refusal(.operationIDConflict, operation: view))
        case .inProgress(let view): return .refused(Refusal(.operationInProgress, operation: view))
        case .replay(let replay):
            guard let blocking = snapshot.state.blocking else { return .replay(replay, state: .ok) }
            return .refused(Refusal(.blocked(blocking), operation: replay.record.view))
        }
        guard ledger.pending().isEmpty else { return .refused(Refusal(.cleanupPending)) }
        let lease: Lease
        do throws(LeaseDenial) {
            lease = try snapshot.lease.check(
                principal: call.principal, holderID: call.arguments.holderID, now: snapshot.reading)
        } catch {
            return .refused(Refusal(error.reason, message: error.message))
        }
        if let limited = ceiling.refusal(at: snapshot.reading.wall) { return .refused(Refusal(limited)) }
        do {
            guard try store.hasCapacity(for: call.principal, now: snapshot.reading.wall) else {
                return .refused(Refusal(.operationCapacity))
            }
        } catch {
            return .refused(storeFault)
        }

        var frontmost: AppRef?
        let use: FrameUse
        switch call.arguments {
        case .pointer: use = .pointer
        case .keyboard:
            let app = seams.identity.frontmostApp()
            frontmost = app.appRef
            use = .keyboard(frontmostApp: app.isCertain ? app.appRef : nil)
        }
        let live: LiveFrame
        let frames = seams.frames
        let (frameID, scope, now) = (call.arguments.frameID, call.scope, snapshot.reading.wall)
        switch await boundedRead({ await frames.check(frameID, in: scope, for: use, now: now) }) {
        case .stale(let reason, let sha256)?:
            return .refused(Refusal(.staleFrame(reason), frontmostApp: frontmost, frameSHA256: sha256))
        case .valid(let checked)?: live = checked
        case nil:
            return .refused(
                Refusal(.internalError, message: "The frame could not be checked in time.", frontmostApp: frontmost))
        }
        func refused(_ reason: ToolErrorReason) -> AdmissionResult {
            .refused(Refusal(reason, frontmostApp: frontmost, frameSHA256: live.frame.sha256))
        }

        let plan: ActionPlan
        let action: CheckedAction
        switch call.arguments {
        case .pointer(let pointer):
            let geometry = live.frame.geometry
            if let outside = geometry.outOfFrame(pointer.action.points) { return refused(outside) }
            guard let targets = PointerTargets(pointer.action, geometry: geometry) else {
                return refused(.outOfFrame(pointIndex: 0, outputPixelSize: geometry.outputPixelSize))
            }
            plan = ActionExpansion.pointer(pointer.action, targets: targets, keyCodes: seams.keyCodes)
            action = CheckedAction(call.arguments, targets: targets)
        case .keyboard:
            guard let keyboardPlan else { return .refused(storeFault) }
            plan = keyboardPlan
            action = .keyboard
        }

        snapshot = seams.state.snapshot()
        if let active = activityCause() { return refused(active) }
        if case .keyboard(let keyboard) = call.arguments, case .press(let press) = keyboard.action,
            let denied = snapshot.policy.evaluate(chord: Chord(press)).toolErrorReason
        {
            ceiling.recordRefusal(denied, at: snapshot.reading.wall)
            return refused(denied)
        }
        var patchCheckedAt: ContinuousClock.Instant?
        if case .pointer(let pointer) = call.arguments {
            let beforeCapture = seams.state.snapshot().reading.monotonic
            let patches = seams.patches
            let verdict = await boundedRead {
                await TargetPatchCheck.run(pointer.action, on: live, verifier: patches)
            }
            guard let verdict else { return refused(.staleFrame(.pixelsChanged(pointIndex: 0))) }
            if let stale = verdict { return refused(.staleFrame(stale)) }
            patchCheckedAt = beforeCapture
        }

        snapshot = seams.state.snapshot()
        let check = AppCheck.run(
            .admission, action: action, permittedApps: call.arguments.permittedApps, binding: nil, snapshot: snapshot,
            identity: seams.identity)
        frontmost = check.frontmost.appRef
        if let denial = check.denial {
            ceiling.recordRefusal(denial, at: snapshot.reading.wall)
            return refused(denial)
        }
        guard let measured = check.measured else { return refused(.internalError) }

        let intent = ActionLogIntent(
            time: snapshot.reading.wall, nodeAddress: call.nodeAddress, principal: call.principal,
            holderID: call.arguments.holderID, operationID: call.arguments.operationID,
            frameID: call.arguments.frameID, frameSHA256: live.frame.sha256, frontmostApp: measured.frontmostApp,
            action: call.arguments.loggedAction)
        let log = seams.log
        let pending = PendingIntent()
        let committed = await logAppend { () async -> IntentReceipt? in
            let receipt: IntentReceipt?
            do throws(ActionLogFailure) {
                receipt = try await log.commitIntent(intent)
            } catch {
                receipt = nil
            }
            if let refusal = pending.appendReturned() { await self.logHeldRefusal(refusal) }
            return receipt
        }
        guard let receipt = committed else {
            var refusal = Refusal(
                .logUnavailable(measured: measured), frontmostApp: frontmost, frameSHA256: live.frame.sha256)
            refusal.afterIntent = pending
            return .refused(refusal)
        }

        guard call.connection.isOpen else {
            return .dropped(Refusal(.cancelled, frontmostApp: frontmost, frameSHA256: live.frame.sha256))
        }
        snapshot = seams.state.snapshot()
        let admission: OperationAdmission
        do {
            admission = try store.admit(receipt, digest: call.digest, now: snapshot.reading.wall)
        } catch {
            return .refused(
                Refusal(
                    .internalError, message: storeFault.message, frontmostApp: frontmost,
                    frameSHA256: live.frame.sha256))
        }
        switch admission {
        case .new(let ticket):
            ceiling.recordAdmission(at: snapshot.reading.wall)
            return .admitted(
                Execution(
                    call: call, ticket: ticket, receipt: receipt, plan: plan, action: action, lease: lease,
                    patchCheckedAt: patchCheckedAt, admissionMeasured: measured))
        case .conflict(let view):
            return .refused(
                Refusal(
                    .operationIDConflict, operation: view, frontmostApp: frontmost, frameSHA256: live.frame.sha256))
        case .inProgress(let view):
            return .refused(
                Refusal(
                    .operationInProgress, operation: view, frontmostApp: frontmost, frameSHA256: live.frame.sha256))
        case .replay(let replay): return .replay(replay, state: .ok)
        case .capacity: return refused(.operationCapacity)
        }
    }

    func refuse(_ call: EffectCall, _ refusal: Refusal) async -> EffectAnswer {
        let snapshot = seams.state.snapshot()
        let error = ToolError(
            refusal.reason, message: refusal.message, state: refusal.reason.reportedState(otherwise: snapshot.state),
            operationID: call.arguments.operationID, operation: refusal.operation.map { .existing($0) })
        await logRefusal(refusalEntry(call, refusal, at: snapshot), after: refusal.afterIntent)
        return .error(error)
    }

    func refusalEntry(_ call: EffectCall, _ refusal: Refusal, at snapshot: DeskSnapshot) -> ActionLogRefusal? {
        ActionLogRefusal(
            time: snapshot.reading.wall, nodeAddress: call.nodeAddress, principal: call.principal,
            tool: call.arguments.tool, holderID: call.arguments.holderID, operationID: call.arguments.operationID,
            frameID: call.arguments.frameID, frameSHA256: refusal.frameSHA256, action: call.arguments.loggedAction,
            frontmostApp: refusal.frontmostApp, code: refusal.reason.code)
    }
}
