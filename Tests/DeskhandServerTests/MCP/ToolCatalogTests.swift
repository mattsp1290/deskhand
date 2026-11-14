import DeskhandCore
import Foundation
import Testing

@testable import DeskhandServer

/// `tools/list` serves `docs/schemas/` after the bundling rule of contract 3.2, and the embedded copy
/// never drifts from the files.
@Suite struct ToolCatalogTests {
    static func servedTools() throws -> [JSONValue] {
        guard case .array(let tools)? = try ToolCatalog.listResult.get()["tools"] else {
            throw ToolCatalogError(description: "no tools array")
        }
        return tools
    }

    @Test func embeddedSchemasAreTheFilesByteForByte() throws {
        let toolFiles = try FileManager.default.contentsOfDirectory(
            atPath: MCPTest.schemas.appendingPathComponent("tools").path
        ).filter { $0.hasSuffix(".json") }.map { "tools/\($0)" }
        #expect(Set(ToolSchemaSources.files.keys) == Set(toolFiles + ["defs.json"]))
        for (path, text) in ToolSchemaSources.files {
            #expect(
                Array(text.utf8) == (try MCPTest.bytes(path)), "\(path) is stale: run scripts/embed-tool-schemas.py")
        }
    }

    /// The rule applied the way `scripts/check-contract.py` applies it: textually, to the serialized
    /// schema with `defs.json`'s definitions merged in.
    @Test(arguments: ToolName.allCases)
    func servedSchemasFollowTheBundlingRule(_ tool: ToolName) throws {
        let served = try #require(try Self.servedTools().first { $0["name"] == .string(tool.rawValue) })
        let defs = try #require(try MCPTest.json("defs.json")["$defs"]?.objectValue)
        for (member, direction) in [("inputSchema", "input"), ("outputSchema", "output")] {
            guard case .object(var schema) = try MCPTest.json("tools/\(tool.rawValue).\(direction).json") else {
                Issue.record("tools/\(tool.rawValue).\(direction).json is not an object")
                continue
            }
            schema["$id"] = nil
            var local = schema["$defs"]?.objectValue ?? [:]
            #expect(Set(local.keys).isDisjoint(with: defs.keys))
            local.merge(defs) { own, _ in own }
            schema["$defs"] = .object(local)
            let text = try JSONValue.object(schema).canonicalString()
                .replacingOccurrences(of: "../defs.json#/$defs/", with: "#/$defs/")
            let expected = try JSONValue(parsing: text)
            #expect(served[member] == expected)

            let servedText = try #require(try served[member]?.canonicalString())
            #expect(!servedText.contains("defs.json"))
            #expect(served[member]?["$id"] == nil)
            #expect(served[member]?["$schema"] == "https://json-schema.org/draft/2020-12/schema")
            let servedDefs = served[member]?["$defs"]?.objectValue ?? [:]
            for reference in Self.references(in: served[member] ?? .null) {
                #expect(reference.hasPrefix("#/$defs/"), "\(reference) is not local")
                #expect(servedDefs[String(reference.dropFirst("#/$defs/".count))] != nil, "\(reference) dangles")
            }
        }
    }

    static func references(in value: JSONValue) -> [String] {
        switch value {
        case .object(let members):
            (members["$ref"]?.stringValue.map { [$0] } ?? []) + members.values.flatMap(references)
        case .array(let elements): elements.flatMap(references)
        default: []
        }
    }

    /// The table of contract 3.2.
    static let table: [(ToolName, String, [Bool])] = [
        (.status, "Status", [true, false, true, false]),
        (.displays, "List displays", [true, false, true, false]),
        (.screenshot, "Take a screenshot", [true, false, false, true]),
        (.pointer, "Pointer input", [false, true, true, true]),
        (.keyboard, "Keyboard input", [false, true, true, true]),
        (.lease, "Lease", [false, false, false, false]),
    ]

    @Test func toolsAreListedInOrderWithTitlesDescriptionsAndExplicitAnnotations() throws {
        let tools = try Self.servedTools()
        #expect(tools.count == Self.table.count)
        for (tool, (name, title, hints)) in zip(tools, Self.table) {
            #expect(tool["name"] == .string(name.rawValue))
            #expect(tool["title"] == .string(title))
            #expect(tool["description"] == (try MCPTest.json("tools/\(name.rawValue).input.json")["description"]))
            let annotations: JSONValue = [
                "readOnlyHint": .bool(hints[0]), "destructiveHint": .bool(hints[1]),
                "idempotentHint": .bool(hints[2]), "openWorldHint": .bool(hints[3]),
            ]
            #expect(tool["annotations"] == annotations)
        }
    }

    @Test func bundlingRefusesADefinitionNameThatCollides() {
        #expect(throws: ToolCatalogError.self) {
            try ToolCatalog.bundle(["$defs": ["holder_id": true]], defs: ["holder_id": false])
        }
    }

    @Test func missingSchemaIsAnInternalErrorNotACrash() {
        var sources = ToolSchemaSources.files
        sources["tools/lease.output.json"] = nil
        #expect(throws: ToolCatalogError.self) { try ToolCatalog.makeListResult(sources: sources) }
    }
}
