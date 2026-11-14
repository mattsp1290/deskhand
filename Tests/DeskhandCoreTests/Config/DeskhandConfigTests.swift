import DeskhandCore
import Foundation
import Testing

@Suite struct DeskhandConfigTests {
    private static func issues(_ document: JSONValue) -> [ConfigIssue] {
        do {
            _ = try DeskhandConfig(json: document)
            return []
        } catch {
            guard case .invalid(let issues) = error else { return [] }
            return issues
        }
    }

    private static func pointer(_ text: String) -> JSONPointer {
        JSONPointer(text.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init))
    }

    @Test func exampleParsesEveryMember() throws {
        let config = try DeskhandConfig(parsing: Array(ConfigFixtures.example.utf8))
        #expect(config.mac == "lunus-macbook-pro")
        #expect(config.listen.address.description == "10.0.0.149")
        #expect(config.listen.address.family == .ipv4)
        #expect(config.listen.port == 8443)
        #expect(
            config.service.names == [
                "deskhand-lunus-macbook-pro.forge.svc", "deskhand-lunus-macbook-pro.forge.svc.cluster.local",
            ])
        #expect(config.service.port == 443)
        #expect(config.credentials.tokenPath == "/Users/deskhand/Library/Application Support/deskhand/token")
        #expect(config.credentials.tokenOverlapMs == 0)
        #expect(config.allowance.path == "/var/run/birbhomes/deskhand-allowance.json")
        #expect(config.allowance.skewToleranceMs == 0)
        #expect(
            config.allowedApps == [
                AllowedApp(bundleID: try #require(BundleID("com.apple.TextEdit")), signer: .apple),
                AllowedApp(
                    bundleID: try #require(BundleID("com.example.Editor")),
                    signer: .team(try #require(TeamID("ABCDE12345")))),
            ])
        #expect(config.limits == Limits())
    }

    @Test func omittedOptionalMembersTakeTheContractDefaults() throws {
        let config = try DeskhandConfig(json: ConfigFixtures.minimal)
        #expect(config.mac == "m1max2021")
        #expect(config.credentials.tokenOverlapMs == 0)
        #expect(config.allowance.skewToleranceMs == 0)
        #expect(config.allowedApps.isEmpty)
        #expect(config.limits.frameMaxAgeMs == 60_000)
        #expect(config.limits.actionsPerMinute == 60)
        #expect(config.limits.operationRetentionMs == 86_400_000)
        #expect(config.limits.operationMaxRecords == 10_000)
    }

    @Test func configuredLimitsFeedStatusLimits() throws {
        let document = ConfigFixtures.minimal(
            setting: ["limits"],
            to: [
                "frame_max_age_ms": 5000, "actions_per_minute": 30, "operation_retention_ms": 3_600_000,
                "operation_max_records": 500,
            ])
        let config = try DeskhandConfig(json: document)
        #expect(
            config.limits
                == Limits(
                    frameMaxAgeMs: 5000, actionsPerMinute: 30, operationRetentionMs: 3_600_000,
                    operationMaxRecords: 500))
        #expect(config.limits.jsonValue["actions_per_minute"] == 30)
        #expect(ActionCeiling(limits: config.limits).actionsPerMinute == 30)
    }

    struct Invalid: CustomTestStringConvertible, Sendable {
        let name: String
        let path: [String]
        let value: JSONValue?
        let pointer: String
        let rule: ConfigRule
        var testDescription: String { name }
    }

    static let invalidCases: [Invalid] = [
        Invalid(name: "unknown top-level member", path: ["extra"], value: 1, pointer: "/extra", rule: .unknownMember),
        Invalid(
            name: "unknown nested member", path: ["listen", "interface"], value: "en0", pointer: "/listen/interface",
            rule: .unknownMember),
        Invalid(
            name: "contract constant is not configurable", path: ["limits", "user_activity_lookback_ms"], value: 3000,
            pointer: "/limits/user_activity_lookback_ms", rule: .unknownMember),
        Invalid(name: "missing mac", path: ["mac"], value: nil, pointer: "/mac", rule: .missingMember),
        Invalid(
            name: "missing listen port", path: ["listen", "port"], value: nil, pointer: "/listen/port",
            rule: .missingMember),
        Invalid(name: "version 2", path: ["version"], value: 2, pointer: "/version", rule: .version(1)),
        Invalid(
            name: "version string", path: ["version"], value: "1", pointer: "/version", rule: .version(1)),
        Invalid(name: "uppercase mac", path: ["mac"], value: "M1Max2021", pointer: "/mac", rule: .macName),
        Invalid(name: "empty mac", path: ["mac"], value: "", pointer: "/mac", rule: .macName),
        Invalid(
            name: "64-character mac", path: ["mac"], value: .string(String(repeating: "a", count: 64)),
            pointer: "/mac", rule: .macName),
        Invalid(name: "mac not a string", path: ["mac"], value: 7, pointer: "/mac", rule: .string),
        Invalid(name: "listen not an object", path: ["listen"], value: "10.0.0.96", pointer: "/listen", rule: .object),
        Invalid(
            name: "listen on all interfaces", path: ["listen", "address"], value: "0.0.0.0",
            pointer: "/listen/address", rule: .listenAddress(.refused(.unspecified))),
        Invalid(
            name: "listen on all IPv6 interfaces", path: ["listen", "address"], value: "::",
            pointer: "/listen/address", rule: .listenAddress(.refused(.unspecified))),
        Invalid(
            name: "listen on loopback", path: ["listen", "address"], value: "127.0.0.1", pointer: "/listen/address",
            rule: .listenAddress(.refused(.loopback))),
        Invalid(
            name: "listen on IPv6 loopback", path: ["listen", "address"], value: "::1", pointer: "/listen/address",
            rule: .listenAddress(.refused(.loopback))),
        Invalid(
            name: "listen on a host name", path: ["listen", "address"], value: "localhost",
            pointer: "/listen/address", rule: .listenAddress(.notIPLiteral)),
        Invalid(
            name: "listen port 0", path: ["listen", "port"], value: 0, pointer: "/listen/port",
            rule: .integer(1...65_535)),
        Invalid(
            name: "listen port fractional", path: ["listen", "port"], value: 8443.5, pointer: "/listen/port",
            rule: .integer(1...65_535)),
        Invalid(
            name: "service port too large", path: ["service", "port"], value: 65_536, pointer: "/service/port",
            rule: .integer(1...65_535)),
        Invalid(
            name: "no service names", path: ["service", "names"], value: [], pointer: "/service/names",
            rule: .array(count: 1...8)),
        Invalid(
            name: "service name with uppercase", path: ["service", "names", "0"],
            value: "Deskhand-m1max2021.forge.svc", pointer: "/service/names/0", rule: .dnsName),
        Invalid(
            name: "service name as IP literal", path: ["service", "names", "0"], value: "10.0.0.96",
            pointer: "/service/names/0", rule: .dnsName),
        Invalid(
            name: "service name with trailing dot", path: ["service", "names", "0"],
            value: "deskhand-m1max2021.forge.svc.", pointer: "/service/names/0", rule: .dnsName),
        Invalid(
            name: "service name with port", path: ["service", "names", "0"], value: "deskhand-m1max2021.forge.svc:443",
            pointer: "/service/names/0", rule: .dnsName),
        Invalid(
            name: "service name label ending in hyphen", path: ["service", "names", "0"],
            value: "deskhand-.forge.svc", pointer: "/service/names/0", rule: .dnsName),
        Invalid(
            name: "service name label of 64 characters", path: ["service", "names", "0"],
            value: .string(String(repeating: "a", count: 64) + ".svc"), pointer: "/service/names/0", rule: .dnsName),
        Invalid(
            name: "relative credential path", path: ["credentials", "token_path"], value: "token",
            pointer: "/credentials/token_path", rule: .absolutePath),
        Invalid(
            name: "credential path with NUL", path: ["credentials", "token_path"], value: "/etc/token\u{0}x",
            pointer: "/credentials/token_path", rule: .absolutePath),
        Invalid(
            name: "token overlap over an hour", path: ["credentials", "token_overlap_ms"], value: 3_600_001,
            pointer: "/credentials/token_overlap_ms", rule: .integer(0...3_600_000)),
        Invalid(
            name: "token path equals key path", path: ["credentials", "token_path"],
            value: "/etc/deskhand/server-key.pem", pointer: "/credentials/token_path",
            rule: .distinctPath(from: pointer("/credentials/server_key_path"))),
        Invalid(
            name: "allowance path equals CA path", path: ["allowance", "path"], value: "/etc/deskhand/ca.pem",
            pointer: "/allowance/path", rule: .distinctPath(from: pointer("/credentials/ca_certificate_path"))),
        Invalid(
            name: "negative skew tolerance", path: ["allowance", "skew_tolerance_ms"], value: -1,
            pointer: "/allowance/skew_tolerance_ms", rule: .integer(0...60_000)),
        Invalid(
            name: "skew tolerance over 60 s", path: ["allowance", "skew_tolerance_ms"], value: 60_001,
            pointer: "/allowance/skew_tolerance_ms", rule: .integer(0...60_000)),
        Invalid(
            name: "allow not an array", path: ["app_policy", "allow"], value: "com.apple.TextEdit",
            pointer: "/app_policy/allow", rule: .array(count: 0...256)),
        Invalid(
            name: "allow entry without team_id", path: ["app_policy", "allow"],
            value: [["bundle_id": "com.apple.TextEdit"]], pointer: "/app_policy/allow/0/team_id",
            rule: .missingMember),
        Invalid(
            name: "allow entry with lowercase team_id", path: ["app_policy", "allow"],
            value: [["bundle_id": "com.example.Editor", "team_id": "abcde12345"]],
            pointer: "/app_policy/allow/0/team_id", rule: .teamID),
        Invalid(
            name: "allow entry with short team_id", path: ["app_policy", "allow"],
            value: [["bundle_id": "com.example.Editor", "team_id": "ABCDE"]], pointer: "/app_policy/allow/0/team_id",
            rule: .teamID),
        Invalid(
            name: "allow entry with numeric team_id", path: ["app_policy", "allow"],
            value: [["bundle_id": "com.example.Editor", "team_id": 12345]], pointer: "/app_policy/allow/0/team_id",
            rule: .teamID),
        Invalid(
            name: "allow entry with bad bundle_id", path: ["app_policy", "allow"],
            value: [["bundle_id": "com.example.Editor\n", "team_id": "ABCDE12345"]],
            pointer: "/app_policy/allow/0/bundle_id", rule: .bundleID),
        Invalid(
            name: "allow entry with unknown member", path: ["app_policy", "allow"],
            value: [["bundle_id": "com.example.Editor", "team_id": "ABCDE12345", "name": "Editor"]],
            pointer: "/app_policy/allow/0/name", rule: .unknownMember),
        Invalid(
            name: "duplicate allow entry", path: ["app_policy", "allow"],
            value: [
                ["bundle_id": "com.example.Editor", "team_id": "ABCDE12345"],
                ["bundle_id": "com.example.Editor", "team_id": "ABCDE12345"],
            ], pointer: "/app_policy/allow/1", rule: .unique(firstAt: pointer("/app_policy/allow/0"))),
        Invalid(
            name: "frame max age under 5 s", path: ["limits", "frame_max_age_ms"], value: 4999,
            pointer: "/limits/frame_max_age_ms", rule: .integer(5000...600_000)),
        Invalid(
            name: "frame max age over 10 min", path: ["limits", "frame_max_age_ms"], value: 600_001,
            pointer: "/limits/frame_max_age_ms", rule: .integer(5000...600_000)),
        Invalid(
            name: "zero actions per minute", path: ["limits", "actions_per_minute"], value: 0,
            pointer: "/limits/actions_per_minute", rule: .integer(1...600)),
        Invalid(
            name: "retention over 7 days", path: ["limits", "operation_retention_ms"], value: 604_800_001,
            pointer: "/limits/operation_retention_ms", rule: .integer(60_000...604_800_000)),
        Invalid(
            name: "zero max records", path: ["limits", "operation_max_records"], value: 0,
            pointer: "/limits/operation_max_records", rule: .integer(1...100_000)),
    ]

    @Test(arguments: invalidCases)
    func invalidValueIsReportedWithPointerAndRule(_ invalid: Invalid) {
        let found = Self.issues(ConfigFixtures.minimal(setting: invalid.path, to: invalid.value))
        #expect(found == [ConfigIssue(Self.pointer(invalid.pointer), invalid.rule)])
    }

    @Test func duplicateServiceNameNamesBothPositions() {
        let document = ConfigFixtures.minimal(
            setting: ["service", "names"], to: ["deskhand-m1max2021.forge.svc", "deskhand-m1max2021.forge.svc"])
        #expect(
            Self.issues(document) == [
                ConfigIssue(Self.pointer("/service/names/1"), .unique(firstAt: Self.pointer("/service/names/0")))
            ])
    }

    @Test func everyIssueIsReportedNotOnlyTheFirst() {
        var document = ConfigFixtures.minimal(setting: ["mac"], to: "Not A Mac")
        document = ConfigFixtures.setting(document, ["listen", "address"], to: "0.0.0.0")
        document = ConfigFixtures.setting(document, ["limits", "actions_per_minute"], to: 0)
        document = ConfigFixtures.setting(document, ["bogus"], to: true)
        let found = Set(Self.issues(document))
        #expect(
            found == [
                ConfigIssue(Self.pointer("/mac"), .macName),
                ConfigIssue(Self.pointer("/listen/address"), .listenAddress(.refused(.unspecified))),
                ConfigIssue(Self.pointer("/limits/actions_per_minute"), .integer(1...600)),
                ConfigIssue(Self.pointer("/bogus"), .unknownMember),
            ])
    }

    @Test func rootThatIsNotAnObjectIsOneIssue() {
        #expect(Self.issues([1, 2]) == [ConfigIssue(.root, .object)])
    }

    @Test func emptyObjectNamesEveryMissingSection() {
        let missing = Self.issues([:]).map(\.pointer.description)
        #expect(missing == ["/version", "/mac", "/listen", "/service", "/credentials", "/allowance"])
        #expect(Self.issues([:]).allSatisfy { $0.rule == .missingMember })
    }

    @Test func duplicateKeysAreRefusedByTheParser() {
        let text = #"{"version": 1, "version": 1}"#
        let error = #expect(throws: ConfigError.self) { try DeskhandConfig(parsing: Array(text.utf8)) }
        guard case .notJSON(let parse) = error else {
            Issue.record("expected notJSON, got \(String(describing: error))")
            return
        }
        #expect(parse.reason == "duplicate key")
    }

    @Test func bothMacNamesAreAccepted() throws {
        for mac in ["lunus-macbook-pro", "m1max2021"] {
            let config = try DeskhandConfig(json: ConfigFixtures.minimal(setting: ["mac"], to: .string(mac)))
            #expect(config.mac == mac)
        }
    }

    @Test func issueDescriptionNamesPointerAndRule() {
        let issue = ConfigIssue(Self.pointer("/listen/address"), .listenAddress(.refused(.loopback)))
        #expect(
            issue.description
                == "/listen/address: must be a unicast LAN address, not a loopback address [listen_address]")
        #expect(ConfigIssue(.root, .object).description == "(root): must be an object [object]")
    }

    @Test func loadReadsAFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskhand-config-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data(ConfigFixtures.example.utf8).write(to: file)

        let config = try DeskhandConfig.load(fromFile: file.path)
        #expect(config.mac == "lunus-macbook-pro")
    }

    @Test func loadRefusesAMissingFile() {
        let error = #expect(throws: ConfigError.self) {
            try DeskhandConfig.load(fromFile: "/nonexistent/deskhand/config.json")
        }
        guard case .unreadable(let path, _) = error else {
            Issue.record("expected unreadable, got \(String(describing: error))")
            return
        }
        #expect(path == "/nonexistent/deskhand/config.json")
    }

    @Test func loadRefusesAnOversizedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskhand-config-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data(repeating: UInt8(ascii: " "), count: DeskhandConfig.maxFileBytes + 1).write(to: file)

        #expect(throws: ConfigError.tooLarge(path: file.path, maxBytes: DeskhandConfig.maxFileBytes)) {
            try DeskhandConfig.load(fromFile: file.path)
        }
    }
}
