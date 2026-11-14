import DeskhandCore

/// The four behavior hints of a tool, always sent explicitly because the specification's defaults
/// (`destructiveHint` and `openWorldHint` true) are wrong for most of deskhand's tools (contract 3.2).
struct ToolAnnotations: Hashable, Sendable {
    let readOnly: Bool
    let destructive: Bool
    let idempotent: Bool
    let openWorld: Bool

    var jsonValue: JSONValue {
        [
            "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
            "idempotentHint": .bool(idempotent), "openWorldHint": .bool(openWorld),
        ]
    }
}

/// Why the embedded schemas could not be served. A test keeps them in step with `docs/schemas/`, so
/// this only happens to a broken build.
struct ToolCatalogError: Error, Hashable, Sendable, CustomStringConvertible {
    let description: String
}

/// The results of `server/discover` and `tools/list` (contract 3.1, 3.2). Neither changes while
/// deskhand runs.
enum ToolCatalog {
    static let defsReference = "../defs.json#/$defs/"
    static let localReference = "#/$defs/"

    /// Title and annotations of each tool: the table of contract 3.2.
    static func entry(for tool: ToolName) -> (title: String, annotations: ToolAnnotations) {
        switch tool {
        case .status:
            ("Status", ToolAnnotations(readOnly: true, destructive: false, idempotent: true, openWorld: false))
        case .displays:
            ("List displays", ToolAnnotations(readOnly: true, destructive: false, idempotent: true, openWorld: false))
        case .screenshot:
            (
                "Take a screenshot",
                ToolAnnotations(readOnly: true, destructive: false, idempotent: false, openWorld: true)
            )
        case .pointer:
            ("Pointer input", ToolAnnotations(readOnly: false, destructive: true, idempotent: true, openWorld: true))
        case .keyboard:
            ("Keyboard input", ToolAnnotations(readOnly: false, destructive: true, idempotent: true, openWorld: true))
        case .lease:
            ("Lease", ToolAnnotations(readOnly: false, destructive: false, idempotent: false, openWorld: false))
        }
    }

    static func discoverResult(serverVersion: String) -> JSONValue {
        [
            "resultType": "complete",
            "supportedVersions": [.string(ContractConstants.mcpProtocolVersion)],
            "capabilities": ["tools": ["listChanged": false]],
            "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "deskhand", "version": .string(serverVersion)]],
            "ttlMs": JSONValue(ContractConstants.discoveryTTLMs),
            "cacheScope": "private",
        ]
    }

    /// Built once from the embedded schemas.
    static let listResult: Result<JSONValue, ToolCatalogError> = Result { () throws(ToolCatalogError) in
        try makeListResult(sources: ToolSchemaSources.files)
    }

    /// The six tools in the order of `ToolName`, which is the order of contract 3.2, in one page.
    static func makeListResult(sources: [String: String]) throws(ToolCatalogError) -> JSONValue {
        let defs = try schema("defs.json", in: sources)["$defs"]?.objectValue ?? [:]
        var tools: [JSONValue] = []
        for tool in ToolName.allCases {
            let input = try schema("tools/\(tool.rawValue).input.json", in: sources)
            let output = try schema("tools/\(tool.rawValue).output.json", in: sources)
            guard let description = input["description"]?.stringValue else {
                throw ToolCatalogError(description: "tools/\(tool.rawValue).input.json has no description")
            }
            let (title, annotations) = entry(for: tool)
            tools.append([
                "name": .string(tool.rawValue), "title": .string(title), "description": .string(description),
                "inputSchema": try bundle(input, defs: defs), "outputSchema": try bundle(output, defs: defs),
                "annotations": annotations.jsonValue,
            ])
        }
        return [
            "resultType": "complete", "tools": .array(tools),
            "ttlMs": JSONValue(ContractConstants.discoveryTTLMs), "cacheScope": "private",
        ]
    }

    /// Contract 3.2: copy every entry of `defs.json`'s `$defs` into the schema's own `$defs`, rewrite
    /// each `../defs.json#/$defs/NAME` to `#/$defs/NAME`, and remove `$id`.
    static func bundle(_ schema: JSONObject, defs: JSONObject) throws(ToolCatalogError) -> JSONValue {
        var bundled = schema
        bundled["$id"] = nil
        var local = bundled["$defs"]?.objectValue ?? [:]
        for (name, definition) in defs {
            guard local[name] == nil else {
                throw ToolCatalogError(description: "$defs name '\(name)' is also in defs.json")
            }
            local[name] = definition
        }
        bundled["$defs"] = .object(local)
        return rewritingReferences(.object(bundled))
    }

    private static func rewritingReferences(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(text.replacing(defsReference, with: localReference))
        case .array(let elements): .array(elements.map(rewritingReferences))
        case .object(let members): .object(members.mapValues(rewritingReferences))
        case .null, .bool, .number: value
        }
    }

    private static func schema(_ path: String, in sources: [String: String]) throws(ToolCatalogError) -> JSONObject {
        guard let text = sources[path] else { throw ToolCatalogError(description: "\(path) is not embedded") }
        let value: JSONValue
        do {
            value = try JSONValue(parsing: text)
        } catch {
            throw ToolCatalogError(description: "\(path): \(error)")
        }
        guard case .object(let schema) = value else {
            throw ToolCatalogError(description: "\(path) is not a JSON object")
        }
        return schema
    }
}
