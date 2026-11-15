import DeskhandCore
import Foundation

enum Fixtures {
    static let schemas = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/schemas")

    static func names(in directory: String, kind: String) -> [String] {
        let path = schemas.appendingPathComponent(directory).path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0.contains(kind) }.sorted()
    }

    static func json(_ relativePath: String) throws -> JSONValue {
        let data = try Data(contentsOf: schemas.appendingPathComponent(relativePath))
        return try JSONValue(parsing: data)
    }

    static func tool(of name: String) -> ToolName? {
        ToolName(rawValue: String(name.prefix { $0 != "." }))
    }
}
