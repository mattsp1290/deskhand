enum CheckScope: Hashable, Sendable {
    case admission
    case lastLook
    case event(CheckTarget)
}

enum CheckedAction: Sendable {
    case keyboard
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

struct IdentityBinding: Hashable, Sendable {
    private(set) var frontmost: AppIdentity
    let keyboardFocus: AppIdentity?
    private(set) var activatable: AppIdentity?

    init(frontmost: AppIdentity, keyboardFocus: AppIdentity?) {
        self.frontmost = frontmost
        self.keyboardFocus = keyboardFocus
    }

    func accepts(frontmost observed: AppIdentity) -> Bool {
        observed == frontmost || observed == activatable
    }

    mutating func follow(frontmost observed: AppIdentity) {
        if accepts(frontmost: observed) { frontmost = observed }
    }

    mutating func didPostButtonDown(over owner: AppIdentity) { activatable = owner }
}

struct AppCheck: Sendable {
    let frontmost: ObservedApp
    let keyboardFocus: ObservedApp?
    let pointOwner: ObservedApp?
    let measured: Measured?
    let denial: ToolErrorReason?

    private struct Subject {
        let app: ObservedApp
        let point: PointerTarget?
    }

    static func run(
        _ scope: CheckScope, action: CheckedAction, permittedApps permitted: Set<BundleID>?, binding: IdentityBinding?,
        snapshot: DeskSnapshot, identity: any IdentityMeasurer
    ) -> AppCheck {
        let now = snapshot.reading.wall
        let policy = snapshot.policy
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

    var binding: IdentityBinding {
        IdentityBinding(frontmost: frontmost.policyIdentity, keyboardFocus: keyboardFocus?.policyIdentity)
    }
}
