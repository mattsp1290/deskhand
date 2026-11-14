import DeskhandCore
import Testing

@Suite struct ActionCeilingTests {
    private static let start = Timestamp(millisecondsSinceEpoch: 1_794_668_400_000)

    private static func at(_ milliseconds: Int64) -> Timestamp { start.adding(milliseconds: milliseconds) }

    /// Runs the step-6 check and, when it passes, admits the call, as the admission owner does.
    private static func attempt(_ ceiling: inout ActionCeiling, at now: Timestamp) -> ToolErrorReason? {
        if let refusal = ceiling.refusal(at: now) { return refusal }
        ceiling.recordAdmission(at: now)
        return nil
    }

    @Test func defaultCeilingAdmitsSixtyThenRefusesWithRetryAfter() {
        var ceiling = ActionCeiling(limits: Limits())
        for index in 0..<60 {
            #expect(Self.attempt(&ceiling, at: Self.at(Int64(index) * 100)) == nil)
        }
        #expect(Self.attempt(&ceiling, at: Self.at(6000)) == .rateLimited(retryAfterMs: 54_000))
        #expect(ToolErrorReason.rateLimited(retryAfterMs: 1).code == .rateLimited)
    }

    /// Contract 9.5, D9: `denied_app` and `denied_shortcut` refusals before admission count, so the
    /// policy cannot be probed without limit; no other refusal does.
    @Test func policyRefusalsCountAndOthersDoNot() {
        var ceiling = ActionCeiling(actionsPerMinute: 3)
        let measured = Measured(
            frontmostApp: .undetermined, targetApp: nil, windowTitle: nil, globalPoint: nil, measuredAt: Self.at(0))
        let counted = [
            ceiling.recordRefusal(.deniedApp(.policy, measured: measured, pointIndex: 0), at: Self.at(0)),
            ceiling.recordRefusal(.deniedShortcut(shortcut: "command+tab"), at: Self.at(1)),
            ceiling.recordRefusal(.staleFrame(.tooOld), at: Self.at(2)),
            ceiling.recordRefusal(.rateLimited(retryAfterMs: 1), at: Self.at(3)),
        ]
        #expect(counted == [true, true, false, false])
        #expect(ceiling.refusal(at: Self.at(4)) == nil)
        ceiling.recordAdmission(at: Self.at(5))
        #expect(ceiling.refusal(at: Self.at(6)) == .rateLimited(retryAfterMs: 59_994))
    }

    @Test func aCeilingBelowOneIsOne() {
        var ceiling = ActionCeiling(actionsPerMinute: 0)
        #expect(ceiling.actionsPerMinute == 1)
        ceiling.recordAdmission(at: Self.at(0))
        #expect(ceiling.refusal(at: Self.at(1)) != nil)
    }

    @Test func retryAfterIsTheEarliestUsefulRetry() {
        var ceiling = ActionCeiling(actionsPerMinute: 3)
        for offset: Int64 in [0, 1000, 2000] { ceiling.recordAdmission(at: Self.at(offset)) }

        #expect(ceiling.refusal(at: Self.at(30_000)) == .rateLimited(retryAfterMs: 30_000))
        #expect(ceiling.refusal(at: Self.at(59_999)) == .rateLimited(retryAfterMs: 1))
        #expect(ceiling.refusal(at: Self.at(60_000)) == nil)
    }

    @Test func refusalsAreNotCounted() {
        var ceiling = ActionCeiling(actionsPerMinute: 2)
        ceiling.recordAdmission(at: Self.at(0))
        ceiling.recordAdmission(at: Self.at(10_000))
        for offset in stride(from: Int64(10_001), to: 60_000, by: 997) {
            #expect(ceiling.refusal(at: Self.at(offset)) != nil)
        }
        #expect(Self.attempt(&ceiling, at: Self.at(60_000)) == nil)
        #expect(Self.attempt(&ceiling, at: Self.at(60_001)) == .rateLimited(retryAfterMs: 9999))
    }

    @Test func checkingDoesNotCount() {
        var ceiling = ActionCeiling(actionsPerMinute: 1)
        for _ in 0..<10 { #expect(ceiling.refusal(at: Self.at(0)) == nil) }
        ceiling.recordAdmission(at: Self.at(0))
        #expect(ceiling.refusal(at: Self.at(0)) == .rateLimited(retryAfterMs: 60_000))
    }

    /// A fixed per-minute bucket would admit 2N across a minute boundary; the sliding window does not.
    @Test func noSixtySecondWindowHoldsMoreThanTheCeiling() {
        var ceiling = ActionCeiling(actionsPerMinute: 5)
        var admitted: [Int64] = []
        for offset in stride(from: Int64(0), to: 300_000, by: 250)
        where Self.attempt(&ceiling, at: Self.at(offset)) == nil {
            admitted.append(offset)
        }
        for (index, first) in admitted.enumerated() {
            let inWindow = admitted[index...].prefix { $0 - first < ActionCeiling.windowMs }
            #expect(inWindow.count <= 5)
        }
        #expect(admitted.count == 25)
    }

    @Test func clockSteppedBackNeitherAdmitsExtraNorLocksOutPastOneWindow() {
        var ceiling = ActionCeiling(actionsPerMinute: 2)
        ceiling.recordAdmission(at: Self.at(3_600_000))
        ceiling.recordAdmission(at: Self.at(3_600_001))

        #expect(ceiling.refusal(at: Self.at(0)) == .rateLimited(retryAfterMs: 60_000))
        #expect(ceiling.refusal(at: Self.at(30_000)) == .rateLimited(retryAfterMs: 30_000))
        #expect(ceiling.refusal(at: Self.at(60_000)) == nil)
    }
}
