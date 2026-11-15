import DeskhandCore
import Foundation

/// The contract's schema examples, found relative to this file so the tests run from any checkout.
enum Fixtures {
    static let schemas = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/schemas")

    /// File names in `docs/schemas/<directory>` whose name contains `kind` (e.g. `.input.`).
    static func names(in directory: String, kind: String) -> [String] {
        let path = schemas.appendingPathComponent(directory).path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0.contains(kind) }.sorted()
    }

    static func json(_ relativePath: String) throws -> JSONValue {
        let data = try Data(contentsOf: schemas.appendingPathComponent(relativePath))
        return try JSONValue(parsing: data)
    }

    /// The tool a fixture belongs to, from its first name component.
    static func tool(of name: String) -> ToolName? {
        ToolName(rawValue: String(name.prefix { $0 != "." }))
    }
}
