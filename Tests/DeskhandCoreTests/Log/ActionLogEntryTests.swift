import DeskhandCore
import DeskhandTestSupport
import Testing

@Suite struct ActionLogEntryTests {
    @Test func intentIsOneCanonicalLine() throws {
        let intent = try LogSamples.intent(keyboard: ["type": "press", "key": "q", "modifiers": ["command", "shift"]])
        let expected =
            #"{"action":{"hold_ms":0,"key":"q","modifiers":["shift","command"],"type":"press"},"#
            + #""frame_id":"frm_AAAAAAAAAAAAAAAAAAAAAA","#
            + #""frame_sha256":"5d2fe555eea829ac791af899610755bc8c5dc4f350bee9abbac1d2144d005fc8","#
            + #""frontmost_app":{"bundle_id":"com.apple.TextEdit","name":"TextEdit","team_id":null},"#
            + #""holder_id":"crew-1","kind":"intent","node_address":"10.0.0.21","operation_id":"op-1","#
            + #""principal":"CN=crew-executor,O=birb","schema_version":1,"time":"2026-11-14T12:00:00.250Z","#
            + #""tool":"keyboard"}"# + "\n"
        #expect(LogSamples.text(ActionLogLine(.intent(intent))) == expected)
    }

    /// Contract 12.10: an outcome also names the apps of the result's `measured`, never its title.
    /// It repeats the intent's frame and action (re-review A, finding 4), so a line read alone still
    /// says what was done.
    @Test func outcomeRepeatsTheIntentsCallerAndHandles() async throws {
        let intent = try LogSamples.intent(keyboard: LogSamples.typing("abc"))
        let line = try await LogSamples.outcomeLine(.aborted(.userActive, eventsPosted: 3), intent: intent)
        let expected =
            #"{"action":{"text_length":3,"type":"type"},"frame_id":"frm_AAAAAAAAAAAAAAAAAAAAAA","#
            + #""frame_sha256":"5d2fe555eea829ac791af899610755bc8c5dc4f350bee9abbac1d2144d005fc8","#
            + #""frontmost_app":{"bundle_id":"com.apple.TextEdit","name":"TextEdit","team_id":null},"#
            + #""holder_id":"crew-1","intent_time":"2026-11-14T12:00:00.250Z","kind":"outcome","#
            + #""node_address":"10.0.0.21","operation_id":"op-1","#
            + #""outcome":{"code":"user_active","events_posted":3,"status":"aborted"},"#
            + #""principal":"CN=crew-executor,O=birb","schema_version":1,"#
            + #""target_app":{"bundle_id":"com.apple.Preview","name":"Preview","team_id":null},"#
            + #""time":"2026-11-14T12:00:01.750Z","tool":"keyboard"}"# + "\n"
        #expect(LogSamples.text(line) == expected)
        #expect(!LogSamples.text(line).contains("secret title"))
    }

    @Test func outcomeWithNothingMeasuredHasNullApps() async throws {
        let intent = try LogSamples.intent(keyboard: LogSamples.typing("abc"))
        let line = try await LogSamples.outcomeLine(.failedBeforeExecution, intent: intent, measured: nil)
        #expect(try ActionLogLine(verifying: line.bytes) == line)
        #expect(line.entry.jsonValue["frontmost_app"] == .null && line.entry.jsonValue["target_app"] == .null)
        let noTarget = Measured(
            frontmostApp: LogSamples.textEdit, targetApp: nil, windowTitle: nil, globalPoint: nil,
            measuredAt: LogSamples.time)
        let partial = try await LogSamples.outcomeLine(.failed(eventsPosted: 0), intent: intent, measured: noTarget)
        #expect(try ActionLogLine(verifying: partial.bytes) == partial)
        #expect(partial.entry.jsonValue["target_app"] == .null)

        let orphanTarget = LogSamples.text(line).replacingFirst(
            #""target_app":null"#, with: #""target_app":{"bundle_id":"a.b","name":"B","team_id":null}"#)
        #expect(throws: ActionLogLineError.self) { try ActionLogLine(verifying: Array(orphanTarget.utf8)) }
        let missing = LogSamples.text(line).replacingFirst(#""target_app":null,"#, with: "")
        #expect(throws: ActionLogLineError.self) { try ActionLogLine(verifying: Array(missing.utf8)) }
    }

    static let pointerActions: [JSONValue] = [
        ["type": "move", "x": 10, "y": -20],
        ["type": "click", "x": 1, "y": 2],
        ["type": "click", "x": 1, "y": 2, "button": "right", "count": 2, "modifiers": ["command", "control"]],
        ["type": "drag", "path": [["x": 0, "y": 0], ["x": 30, "y": 40], ["x": 31, "y": 41]], "duration_ms": 900],
        ["type": "scroll", "x": 5, "y": 6, "dy": -3],
    ]

    @Test(arguments: pointerActions) func pointerIntentRoundTrips(action: JSONValue) throws {
        let line = ActionLogLine(.intent(try LogSamples.intent(pointer: action)))
        #expect(try ActionLogLine(verifying: line.bytes) == line)
        #expect(line.entry.jsonValue["action"]?["type"] == action["type"])
    }

    static let keyboardActions: [JSONValue] = [
        LogSamples.typing("hello"),
        ["type": "press", "key": "return"],
        ["type": "press", "key": "a", "modifiers": ["shift"], "hold_ms": 250],
        ["type": "press", "key": "c", "modifiers": ["control"]],
        ["type": "press", "key": "f5", "modifiers": ["option"]],
    ]

    @Test(arguments: keyboardActions) func keyboardIntentRoundTrips(action: JSONValue) throws {
        let line = ActionLogLine(.intent(try LogSamples.intent(keyboard: action)))
        #expect(try ActionLogLine(verifying: line.bytes) == line)
    }

    static let outcomes: [(ActionOutcome, OperationStatus, ToolErrorCode?, Int)] = [
        (.completed(eventsPosted: 4), .completed, nil, 4),
        (.aborted(.userActive, eventsPosted: 1), .aborted, .userActive, 1),
        (.aborted(.state(.locked), eventsPosted: 0), .aborted, .locked, 0),
        (.aborted(.state(.gated), eventsPosted: 2), .aborted, .gated, 2),
        (.aborted(.deniedApp, eventsPosted: 5), .aborted, .deniedApp, 5),
        (.aborted(.leaseExpired, eventsPosted: 5), .aborted, .leaseExpired, 5),
        (.aborted(.leaseNotHeld, eventsPosted: 5), .aborted, .leaseNotHeld, 5),
        (.aborted(.cancelled, eventsPosted: 5), .aborted, .cancelled, 5),
        (.failed(eventsPosted: 2), .failed, .internalError, 2),
        (.failedBeforeExecution, .failedBeforeExecution, .interrupted, 0),
        (.abortedByRestart(eventsPosted: 7), .abortedByRestart, .interrupted, 7),
    ]

    @Test(arguments: outcomes) func outcomeCarriesStatusAndCode(
        outcome: ActionOutcome, status: OperationStatus, code: ToolErrorCode?, events: Int
    ) async throws {
        #expect(outcome.status == status)
        #expect(outcome.code == code)
        #expect(outcome.eventsPosted == events)
        let intent = try LogSamples.intent(pointer: ["type": "move", "x": 1, "y": 1])
        let line = try await LogSamples.outcomeLine(outcome, intent: intent)
        #expect(try ActionLogLine(verifying: line.bytes) == line)
        guard case .outcome(let logged) = line.entry else {
            Issue.record("expected an outcome entry")
            return
        }
        #expect(logged.outcome == outcome)
        #expect(logged.operationID == intent.operationID)
        #expect(logged.intentTime == intent.time)
        #expect(logged.tool == .pointer)
    }

    @Test func timestampsAndIPv6RoundTrip() throws {
        let base = try LogSamples.intent(keyboard: LogSamples.typing("x"))
        for (milliseconds, address) in [(0, "fe80::1"), (1_794_657_600_000, "2001:db8::8:800:200c:417a"), (-1, "::")] {
            let intent = ActionLogIntent(
                time: Timestamp(millisecondsSinceEpoch: Int64(milliseconds)),
                nodeAddress: try #require(NodeAddress(address)),
                principal: base.principal, holderID: base.holderID, operationID: base.operationID,
                frameID: base.frameID, frameSHA256: base.frameSHA256,
                frontmostApp: AppRef(bundleID: nil, teamID: "ABCDE12345", name: "Finder \"quoted\""),
                action: base.action)
            let line = ActionLogLine(.intent(intent))
            #expect(try ActionLogLine(verifying: line.bytes) == line)
        }
    }

    /// Bytes the writer must refuse, each a small edit of a valid intent line.
    static let tamperedIntents: [(String, @Sendable (String) -> String)] = [
        ("no line feed", { String($0.dropLast()) }),
        ("two line feeds", { $0 + "\n" }),
        ("whitespace", { $0.replacingFirst(#""kind":"intent""#, with: #""kind": "intent""#) }),
        (
            "member order",
            { #"{"tool":"keyboard","# + String($0.dropFirst()).replacingFirst(#","tool":"keyboard""#, with: "") }
        ),
        ("unknown member", { $0.replacingFirst(#""kind":"intent""#, with: #""kind":"intent","text":"hi""#) }),
        ("schema version", { $0.replacingFirst(#""schema_version":1"#, with: #""schema_version":2"#) }),
        ("not an effect tool", { $0.replacingFirst(#""tool":"keyboard""#, with: #""tool":"status""#) }),
        ("wrong tool", { $0.replacingFirst(#""tool":"keyboard""#, with: #""tool":"pointer""#) }),
        ("typed key named", { $0.replacingFirst(#""key":null"#, with: #""key":"p""#) }),
        ("text instead of length", { $0.replacingFirst(#""key":null"#, with: #""key":null,"text":"p""#) }),
        ("time spelling", { $0.replacingFirst("00:00.250Z", with: "00:00.2500Z") }),
        ("time zone", { $0.replacingFirst("00:00.250Z", with: "00:00.250+00:00") }),
        ("node address spelling", { $0.replacingFirst("10.0.0.21", with: "10.0.0.021") }),
        ("node address hostname", { $0.replacingFirst("10.0.0.21", with: "node-a") }),
        ("digest case", { $0.replacingFirst("5d2fe555", with: "5D2FE555") }),
    ]

    @Test(arguments: tamperedIntents.indices) func writerRefusesTamperedIntent(index: Int) throws {
        let (name, tamper) = Self.tamperedIntents[index]
        let intent = try LogSamples.intent(keyboard: ["type": "press", "key": "p", "modifiers": ["shift"]])
        let original = LogSamples.text(ActionLogLine(.intent(intent)))
        let tampered = tamper(original)
        #expect(tampered != original, "\(name): the edit did not apply")
        #expect(throws: ActionLogLineError.self, "\(name)") { try ActionLogLine(verifying: Array(tampered.utf8)) }
    }

    /// Re-encoding would reproduce a named typing key byte for byte, so the decoder itself must refuse it.
    @Test func namedTypingKeyIsRefusedAsInvalidNotJustNonCanonical() throws {
        let intent = try LogSamples.intent(keyboard: ["type": "press", "key": "p", "modifiers": ["shift"]])
        let named = LogSamples.text(ActionLogLine(.intent(intent))).replacingFirst(#""key":null"#, with: #""key":"p""#)
        do {
            _ = try ActionLogLine(verifying: Array(named.utf8))
            Issue.record("a named typing key was accepted")
        } catch {
            guard case .invalid(let reason) = error else {
                Issue.record("refused for the wrong reason: \(error)")
                return
            }
            #expect(reason.pointer.description == "/action/key")
        }
    }

    @Test func writerRefusesOutcomesWhoseStatusAndCodeDisagree() async throws {
        let intent = try LogSamples.intent(pointer: ["type": "move", "x": 1, "y": 1])
        let line = LogSamples.text(try await LogSamples.outcomeLine(.completed(eventsPosted: 1), intent: intent))
        let edits = [
            (#"{"events_posted":1,"status":"completed"}"#, #"{"code":"busy","events_posted":1,"status":"completed"}"#),
            (#"{"events_posted":1,"status":"completed"}"#, #"{"code":"busy","events_posted":1,"status":"aborted"}"#),
            (
                #"{"events_posted":1,"status":"completed"}"#,
                #"{"code":"interrupted","events_posted":1,"status":"failed_before_execution"}"#
            ),
            (#"{"events_posted":1,"status":"completed"}"#, #"{"events_posted":-1,"status":"completed"}"#),
            (#""intent_time""#, #""intent_tim""#),
        ]
        for (old, new) in edits {
            let tampered = line.replacingFirst(old, with: new)
            #expect(tampered != line)
            #expect(throws: ActionLogLineError.self) { try ActionLogLine(verifying: Array(tampered.utf8)) }
        }
    }

    /// Contract 12.10: a call refused before admission leaves one best-effort refusal entry, with
    /// every member it could not supply well formed as `null`, and no text.
    @Test func refusalEntriesRoundTripWithAndWithoutHandles() async throws {
        let arguments = try LogSamples.keyboardArguments(LogSamples.typing("secret"))
        let full = try #require(
            ActionLogRefusal(
                time: LogSamples.time, nodeAddress: LogSamples.node, principal: LogSamples.principal,
                tool: .keyboard, holderID: arguments.holderID, operationID: arguments.operationID,
                frameID: arguments.frameID, frameSHA256: LogSamples.frameSHA256,
                action: .keyboard(LoggedKeyboardAction(arguments.action)), frontmostApp: LogSamples.textEdit,
                code: .deniedApp))
        let bare = try #require(
            ActionLogRefusal(
                time: LogSamples.time, nodeAddress: LogSamples.node, principal: LogSamples.principal,
                tool: .pointer, holderID: nil, operationID: nil, frameID: nil, frameSHA256: nil, action: nil,
                frontmostApp: nil, code: .invalidArgument))
        let log = InMemoryActionLog()
        for refusal in [full, bare] {
            try await log.commitRefusal(refusal)
            let line = try #require(await log.lines.last)
            #expect(line.entry == .refusal(refusal))
            #expect(line.entry.kind == .refusal)
            #expect(try ActionLogLine(verifying: line.bytes) == line)
            #expect(!LogSamples.text(line).contains("secret"))
        }
        #expect(LogSamples.text(try #require(await log.lines.last)).contains(#""holder_id":null"#))
        #expect(
            ActionLogRefusal(
                time: LogSamples.time, nodeAddress: LogSamples.node, principal: LogSamples.principal, tool: .status,
                holderID: nil, operationID: nil, frameID: nil, frameSHA256: nil, action: nil, frontmostApp: nil,
                code: .invalidArgument) == nil)
    }

    /// The log's outcome is derived from what the record stores, so the two cannot disagree.
    @Test func outcomesComeFromTheRecordsOutcome() {
        let measured = Measured(
            frontmostApp: LogSamples.textEdit, targetApp: LogSamples.textEdit, windowTitle: nil, globalPoint: nil,
            measuredAt: LogSamples.time)
        let stale = OperationOutcome.aborted(
            ToolError(.staleFrame(.pixelsChanged(pointIndex: 0)), message: "", state: .ok), measured: measured)
        #expect(ActionOutcome(stale, eventsPosted: 0) == .aborted(.staleFrame, eventsPosted: 0))
        let paused = OperationOutcome.aborted(
            ToolError(.blocked(.paused), message: "", state: .paused), measured: measured)
        #expect(ActionOutcome(paused, eventsPosted: 4) == .aborted(.state(.paused), eventsPosted: 4))
        let failed = OperationOutcome.failed(ToolError(.internalError, message: "", state: .ok), measured: measured)
        #expect(ActionOutcome(failed, eventsPosted: 2) == .failed(eventsPosted: 2))
        let busy = OperationOutcome.aborted(ToolError(.busy, message: "", state: .ok), measured: measured)
        #expect(ActionOutcome(busy, eventsPosted: 0) == nil)
        #expect(AbortCause(code: .staleFrame)?.code == .staleFrame)
        #expect(AbortCause(code: .rateLimited) == nil)
    }
}

extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = firstRange(of: target) else { return self }
        var result = self
        result.replaceSubrange(range, with: replacement)
        return result
    }
}
