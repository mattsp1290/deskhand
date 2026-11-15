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

/// The identities an operation was started with (bean bhwb), which every check after the last look
/// holds it to: for `keyboard` the owner of keyboard focus, and the frontmost app as
/// ``accepts(frontmost:)`` decides. A change aborts with `denied_app` even when the new app is
/// allowed, so input never reaches an app nobody measured before the event that reaches it.
struct IdentityBinding: Hashable, Sendable {
    private(set) var frontmost: AppIdentity
    let keyboardFocus: AppIdentity?
    /// `pointer`: the owner of the window under the point of the latest button-down this operation
    /// posted, as the check before that event measured it and the app policy allowed it.
    private(set) var activatable: AppIdentity?

    init(frontmost: AppIdentity, keyboardFocus: AppIdentity?) {
        self.frontmost = frontmost
        self.keyboardFocus = keyboardFocus
    }

    /// Whether `observed` may be the frontmost app now (coordinator decision, bean bhwb).
    ///
    /// A button-down on a window of an app in the background activates that app. So once a
    /// `pointer` operation has posted a button-down, the frontmost app may switch to the app that
    /// owns the policy-checked window under that event's point: the same ``AppIdentity`` that check
    /// measured, which ``activatable`` holds. Activation can land after any later event, so the
    /// switch is accepted at whichever check sees it, and the binding then follows it. Any other
    /// switch is refused: before a button-down, to any other app however allowed, back to the app
    /// it left, and every switch during a `keyboard` call, which posts no button-down.
    func accepts(frontmost observed: AppIdentity) -> Bool {
        observed == frontmost || observed == activatable
    }

    /// Follows a switch ``accepts(frontmost:)`` allowed, so the app left is no longer accepted.
    mutating func follow(frontmost observed: AppIdentity) {
        if accepts(frontmost: observed) { frontmost = observed }
    }

    /// A button-down was posted over a window of `owner`, which its check allowed.
    mutating func didPostButtonDown(over owner: AppIdentity) { activatable = owner }
}

/// One app-policy check: what was measured, and the `denied_app` it ends in, if any.
struct AppCheck: Sendable {
    let frontmost: ObservedApp
    /// `keyboard` only.
    let keyboardFocus: ObservedApp?
    /// `pointer` only: the owner of the window under the first point checked, which for a check
    /// before an event is that event's own point.
    let pointOwner: ObservedApp?
    /// The facts of contract 6.7, with the titles the app policy shows. `nil` for a check before a
    /// later event.
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
        let policy = snapshot.policy
        // A window of an app the policy refuses has no title in `measured`, also when the check
        // ends for a cause that outranks `denied_app` (contract 6.7 nulls it on `denied_app`).
        func title(of window: ObservedWindow) -> WindowTitle? {
            guard policy.refusal(of: window.owner.policyIdentity) == nil else { return nil }
            return policy.windowTitle(window.title, of: window.owner.appRef)
        }
        let frontmost = identity.frontmostApp()
        var subjects = [Subject(app: frontmost, point: nil)]
        let effectTarget: EffectTarget
        var measured: Measured?
        var focus: ObservedApp?
        var pointOwner: ObservedApp?
        var checkedPoint: PointerTarget?
        switch action {
        case .keyboard:
            let window = identity.keyboardFocus()
            focus = window.owner
            subjects.append(Subject(app: window.owner, point: nil))
            effectTarget = .keyboard(focusOwner: window.owner.policyIdentity)
            if scope == .admission || scope == .lastLook {
                measured = Measured(
                    frontmostApp: frontmost.appRef, targetApp: window.owner.appRef, windowTitle: title(of: window),
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
            pointOwner = windows[0].owner
            if scope == .admission || scope == .lastLook, let firstWindow = windows.first, let lastWindow = windows.last
            {
                measured = Measured(
                    frontmostApp: frontmost.appRef, targetApp: firstWindow.owner.appRef,
                    windowTitle: title(of: firstWindow),
                    globalPoint: targets.first.globalPoint,
                    dragEnd: isDrag
                        ? DragEnd(
                            targetApp: lastWindow.owner.appRef, windowTitle: title(of: lastWindow),
                            globalPoint: targets.last.globalPoint) : nil,
                    measuredAt: now)
            }
        }

        func denied(_ deniedBy: DeniedBy, by culprit: Subject, pointIndex: Int?) -> AppCheck {
            let facts = Measured(
                frontmostApp: frontmost.appRef, targetApp: culprit.app.appRef, windowTitle: nil,
                globalPoint: (culprit.point ?? checkedPoint)?.globalPoint, measuredAt: now)
            return AppCheck(
                frontmost: frontmost, keyboardFocus: focus, pointOwner: pointOwner, measured: measured,
                denial: .deniedApp(deniedBy, measured: facts, pointIndex: pointIndex))
        }

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
            if !binding.accepts(frontmost: frontmost.policyIdentity) {
                return denied(.policy, by: subjects[0], pointIndex: nil)
            }
            if let bound = binding.keyboardFocus, let focus, focus.policyIdentity != bound {
                return denied(.policy, by: subjects[1], pointIndex: nil)
            }
        }
        return AppCheck(
            frontmost: frontmost, keyboardFocus: focus, pointOwner: pointOwner, measured: measured, denial: nil)
    }

    /// The identities the rest of the operation must keep, from a last look that passed.
    var binding: IdentityBinding {
        IdentityBinding(frontmost: frontmost.policyIdentity, keyboardFocus: keyboardFocus?.policyIdentity)
    }
}
