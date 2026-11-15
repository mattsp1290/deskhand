import DeskhandCore
import Synchronization
import Testing

@testable import DeskhandServer

private enum ReadTransition: CaseIterable, Sendable {
    case none, recovered, stillBlocked

    var refusal: ToolErrorCode? {
        switch self {
        case .none: nil
        case .recovered: .locked
        case .stillBlocked: .secureInput
        }
    }

    func apply(to owner: DeskOwner) {
        guard self != .none else { return }
        owner.reduce(signals: ToolFixture.signals(holding: [.locked]))
        owner.reduce(signals: ToolFixture.signals(holding: self == .stillBlocked ? [.secureInput] : []))
    }
}

private enum DisplayOutcome: CaseIterable, Sendable {
    case success, failure, noMainDisplay
}

private final class ReadTransitionDisplays: DisplayProvider {
    let hook = Mutex<(@Sendable () -> Void)?>(nil)
    let outcome: DisplayOutcome
    init(_ outcome: DisplayOutcome) { self.outcome = outcome }
    var generation: DisplayConfigGeneration { ToolFixture.generation }
    func configuration() throws(PlatformFault) -> DisplayConfiguration {
        hook.withLock { $0 }?()
        if outcome == .failure { throw PlatformFault("display failure") }
        return DisplayConfiguration(
            generation: generation, displays: outcome == .noMainDisplay ? [] : [ToolFixture.main])
    }
}

@Suite struct ReadTransitionTests {
    @Test(arguments: DisplayOutcome.allCases, ReadTransition.allCases)
    fileprivate func displayOutcomes(outcome: DisplayOutcome, transition: ReadTransition) async throws {
        let harness = try ToolHarness()
        let displays = ReadTransitionDisplays(outcome)
        let clock = harness.clock
        let owner = DeskOwner(policy: ToolFixture.policy, displays: displays, clock: { clock.reading })
        owner.reduce(signals: ToolFixture.signals(), command: .arm(for: .seconds(3600)))
        displays.hook.withLock { $0 = { transition.apply(to: owner) } }
        let dispatcher = DeskhandDispatcher(
            configuration: harness.dispatcher.configuration,
            owner: owner, executor: harness.executor, platform: harness.dispatcher.platform,
            digestKey: ToolFixture.digestKey)
        let error = await refusal { () async throws(ToolError) in
            try await dispatcher.displays(caller: ToolFixture.caller)
        }
        #expect(error?.code == (transition.refusal ?? (outcome == .failure ? .internalError : nil)))
        for invalid in [false, true] {
            owner.reduce(signals: ToolFixture.signals())
            let expected: ToolErrorCode?
            switch (outcome, invalid) {
            case (.failure, _), (.noMainDisplay, false): expected = .internalError
            case (_, true): expected = .invalidArgument
            case (.success, false): expected = nil
            }
            let shotError = await refusal { () async throws(ToolError) in
                try await dispatcher.screenshot(
                    ToolHarness.shot(invalid ? ["display_id": 99] : [:]), caller: ToolFixture.caller)
            }
            #expect(shotError?.code == (transition.refusal ?? expected))
        }
    }

    enum CaptureOutcome: CaseIterable, Sendable {
        case success, thrownSize, thrownFault, empty, oversized, wrongEncoding, wrongSize, cancelled
        var refusal: ToolErrorCode? {
            switch self {
            case .success: nil
            case .thrownSize, .oversized: .imageTooLarge
            default: .internalError
            }
        }
    }

    @Test(arguments: CaptureOutcome.allCases, ReadTransition.allCases)
    fileprivate func captureOutcomes(outcome: CaptureOutcome, transition: ReadTransition) async throws {
        let harness = try ToolHarness()
        let prior = try await harness.screenshot().result.frameID
        let owner = harness.owner
        harness.capturer.configure { behavior in
            switch outcome {
            case .thrownSize: behavior.tooLarge = ContractConstants.maxImageBytes + 1
            case .thrownFault: behavior.fault = true
            case .empty: behavior.imageBytes = 0
            case .oversized: behavior.imageBytes = ContractConstants.maxImageBytes + 1
            case .wrongEncoding: behavior.reportedEncoding = .png
            case .wrongSize: behavior.reportedSize = try! ScreenshotSize(source: PixelSize(width: 3, height: 3))
            case .success, .cancelled: break
            }
            behavior.during = {
                transition.apply(to: owner)
                if outcome == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let task = Task { await refusal { () async throws(ToolError) in try await harness.screenshot() } }
        #expect(await task.value?.code == (transition.refusal ?? outcome.refusal))
        if transition == .none, outcome != .success {
            #expect(await harness.check(prior) == nil)
        }
    }

    @Test func cancelledDisplaysNeverSucceeds() async throws {
        let harness = try ToolHarness()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await refusal { () async throws(ToolError) in
                try await harness.dispatcher.displays(caller: ToolFixture.caller)
            }
        }
        #expect(await task.value?.code == .internalError)
    }
}
