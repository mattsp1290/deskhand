/// Which apps one app-policy check measures (contract 6.7, 6.9, 12.3).
enum CheckScope: Hashable, Sendable {
    /// Refusal step 14: every sample of a `pointer` action.
    case admission
    /// The last look: the first target, and the last point of a `drag` for `drag_end`.
    case lastLook
    /// Before a later event, or at a poll while input is held.
    case event(CheckTarget)
}

/// What an effect acts on, as its app-policy checks see it.
enum CheckedAction: Sendable {
    case keyboard
    /// `isDrag`: the last point is measured too, for `drag_end`.
    case pointer(PointerTargets, isDrag: Bool)

    init(_ arguments: EffectCallArguments, targets: PointerTargets?) {
        switch (arguments, targets) {
        case (.pointer(let pointer), let targets?):
            if case .drag = pointer.action {
                self = .pointer(targets, isDrag: true)
            } else {
                self = .pointer(targets, isDrag: false)
            }
        case (.pointer, nil), (.keyboard, _): self = .keyboard
        }
    }
}

/// The identities an operation was started with (bean bhwb). The frontmost app, and for `keyboard`
/// the owner of keyboard focus, must stay the app measured at the last look: a change aborts with
/// `denied_app` even when the new app is allowed, so input never reaches an app nobody measured
/// before the first event.
struct IdentityBinding: Hashable, Sendable {
    let frontmost: AppIdentity
    let keyboardFocus: AppIdentity?
}

/// One app-policy check: what was measured, and the `denied_app` it ends in, if any.
struct AppCheck: Sendable {
    let frontmost: ObservedApp
    /// `keyboard` only.
    let keyboardFocus: ObservedApp?
    /// The facts of contract 6.7, titles as measured. `nil` for a check before a later event.
    let measured: Measured?
    /// `denied_app`, whose `measured` describes the check that failed.
    let denial: ToolErrorReason?

    private struct Subject {
        let app: ObservedApp
        /// The pointer target whose window this is; `nil` for the frontmost app and keyboard focus.
        let point: PointerTarget?
    }

    /// Measures and decides. `binding` is the last look's, for every check after it.
    static func run(
        _ scope: CheckScope, action: CheckedAction, permittedApps permitted: Set<BundleID>?, binding: IdentityBinding?,
        snapshot: DeskSnapshot, identity: any IdentityMeasurer
    ) -> AppCheck {
        let now = snapshot.reading.wall
        let frontmost = identity.frontmostApp()
        var subjects = [Subject(app: frontmost, point: nil)]
        let effectTarget: EffectTarget
        var measured: Measured?
        var focus: ObservedApp?
        var checkedPoint: PointerTarget?
        switch action {
        case .keyboard:
            let window = identity.keyboardFocus()
            focus = window.owner
            subjects.append(Subject(app: window.owner, point: nil))
            effectTarget = .keyboard(focusOwner: window.owner.policyIdentity)
            if scope == .admission || scope == .lastLook {
                measured = Measured(
                    frontmostApp: frontmost.appRef, targetApp: window.owner.appRef, windowTitle: window.title,
                    globalPoint: nil, measuredAt: now)
            }
        case .pointer(let targets, let isDrag):
            let points: [PointerTarget]
            switch scope {
            case .admission: points = targets.samples
            case .lastLook: points = isDrag ? [targets.first, targets.last] : [targets.first]
            case .event(.point(let target)): points = [target]
            case .event(.keyboardFocus): points = [targets.first]
            }
            let measuredWindows = identity.windows(at: points.map(\.globalPoint))
            let windows = points.indices.map {
                $0 < measuredWindows.count ? measuredWindows[$0] : ObservedWindow(owner: .undetermined, title: nil)
            }
            subjects += zip(points, windows).map { Subject(app: $0.1.owner, point: $0.0) }
            effectTarget = .pointer(
                windowOwners: zip(points, windows).map {
                    WindowOwner(pointIndex: $0.0.pointIndex, app: $0.1.owner.policyIdentity)
                })
            checkedPoint = points[0]
            if scope == .admission || scope == .lastLook, let firstWindow = windows.first, let lastWindow = windows.last
            {
                measured = Measured(
                    frontmostApp: frontmost.appRef, targetApp: firstWindow.owner.appRef, windowTitle: firstWindow.title,
                    globalPoint: targets.first.globalPoint,
                    dragEnd: isDrag
                        ? DragEnd(
                            targetApp: lastWindow.owner.appRef, windowTitle: lastWindow.title,
                            globalPoint: targets.last.globalPoint) : nil,
                    measuredAt: now)
            }
        }

        func denied(_ deniedBy: DeniedBy, by culprit: Subject, pointIndex: Int?) -> AppCheck {
            let facts = Measured(
                frontmostApp: frontmost.appRef, targetApp: culprit.app.appRef, windowTitle: nil,
                globalPoint: (culprit.point ?? checkedPoint)?.globalPoint, measuredAt: now)
            return AppCheck(
                frontmost: frontmost, keyboardFocus: focus, measured: measured,
                denial: .deniedApp(deniedBy, measured: facts, pointIndex: pointIndex))
        }

        let policy = snapshot.policy
        if case .deny(let denial) = policy.evaluate(
            frontmost: frontmost.policyIdentity, target: effectTarget, permittedApps: permitted)
        {
            // `evaluate` refuses the first subject in this same order, by the Mac's policy before
            // `permitted_apps`, so the first subject its rule refuses is the one it reported.
            let culprit = subjects.first { subject in
                let app = subject.app.policyIdentity
                switch denial.deniedBy {
                case .policy: return policy.refusal(of: app) != nil
                case .permittedApps: return !(app.bundleID.map { permitted?.contains($0) ?? true } ?? false)
                }
            }
            return denied(
                denial.deniedBy, by: culprit ?? Subject(app: .undetermined, point: nil),
                pointIndex: denial.subject.pointIndex)
        }
        if let binding {
            if frontmost.policyIdentity != binding.frontmost {
                return denied(.policy, by: subjects[0], pointIndex: nil)
            }
            if let bound = binding.keyboardFocus, let focus, focus.policyIdentity != bound {
                return denied(.policy, by: subjects[1], pointIndex: nil)
            }
        }
        return AppCheck(frontmost: frontmost, keyboardFocus: focus, measured: measured, denial: nil)
    }

    /// The identities the rest of the operation must keep, from a last look that passed.
    var binding: IdentityBinding {
        IdentityBinding(frontmost: frontmost.policyIdentity, keyboardFocus: keyboardFocus?.policyIdentity)
    }
}
