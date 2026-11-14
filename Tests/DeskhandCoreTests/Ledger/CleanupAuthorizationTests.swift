import DeskhandCore
import Testing

/// Contract 12.8: a release needs `locked`, `not_console`, `login_window` and `secure_input` all
/// absent, each judged on its own. Nothing else holds a release back.
@Suite(.timeLimit(.minutes(1))) struct CleanupAuthorizationTests {
    /// What each state blocks when it holds alone.
    private static let stateTable: [(BlockingState, CleanupBlocker?)] = [
        (.gated, nil), (.paused, nil), (.disarmed, nil), (.notConsole, .notConsole), (.locked, .locked),
        (.displayAsleep, nil), (.permissionMissing, nil), (.permissionStale, nil), (.secureInput, .secureInput),
    ]

    /// What each condition blocks when it holds alone.
    private static let conditionTable: [(Condition, CleanupBlocker?)] = [
        (.credentialsWarning, nil), (.cleanupPending, nil), (.logUnavailable, nil),
        (.loginWindow, .loginWindow), (.userActive, nil),
    ]

    @Test func tablesCoverEveryStateAndCondition() {
        #expect(Self.stateTable.map(\.0) == BlockingState.allCases)
        #expect(Self.conditionTable.map(\.0) == Condition.allCases)
        let blockers = (Self.stateTable.map(\.1) + Self.conditionTable.map(\.1)).compactMap { $0 }
        #expect(Set(blockers) == Set(CleanupBlocker.allCases))
    }

    @Test(arguments: stateTable)
    func eachStateAlone(_ state: BlockingState, _ blocker: CleanupBlocker?) {
        let authorization = CleanupAuthorization(active: ActiveStates([state]), conditions: [])
        #expect(authorization == blocker.map { .deferred([$0]) } ?? .authorized)
    }

    @Test(arguments: conditionTable)
    func eachConditionAlone(_ condition: Condition, _ blocker: CleanupBlocker?) {
        let authorization = CleanupAuthorization(active: .none, conditions: [condition])
        #expect(authorization == blocker.map { .deferred([$0]) } ?? .authorized)
    }

    @Test func nothingHoldingIsAuthorized() {
        let authorization = CleanupAuthorization(active: .none, conditions: [])
        #expect(authorization == .authorized && authorization.isAuthorized)
    }

    /// The state `status` reports is not enough: `paused` outranks `locked`, yet the lock blocks.
    @Test func aLowerPrecedenceBlockerStillBlocks() {
        let active = ActiveStates([.paused, .disarmed, .locked])
        #expect(active.current == .paused)
        #expect(CleanupAuthorization(active: active, conditions: []) == .deferred([.locked]))
    }

    @Test func theLoginWindowBlocksBesideNotConsole() {
        let authorization = CleanupAuthorization(active: ActiveStates([.notConsole]), conditions: [.loginWindow])
        #expect(authorization == .deferred([.notConsole, .loginWindow]))
        #expect(!authorization.isAuthorized)
    }

    /// Every combination of states, with and without the login window: the blockers are exactly the
    /// union of what each member blocks alone.
    @Test func everyCombinationIsTheUnionOfItsMembers() {
        let states = BlockingState.allCases
        let blockedBy = Dictionary(uniqueKeysWithValues: Self.stateTable)
        for mask in 0..<(1 << states.count) {
            let active = states.indices.filter { mask & (1 << $0) != 0 }.map { states[$0] }
            for conditions in [Set(Condition.allCases).subtracting([.loginWindow]), Set(Condition.allCases)] {
                var expected = Set(active.compactMap { blockedBy[$0] ?? nil })
                if conditions.contains(.loginWindow) { expected.insert(.loginWindow) }
                let authorization = CleanupAuthorization(active: ActiveStates(active), conditions: conditions)
                #expect(authorization == (expected.isEmpty ? .authorized : .deferred(expected)), "\(active)")
            }
        }
    }
}
