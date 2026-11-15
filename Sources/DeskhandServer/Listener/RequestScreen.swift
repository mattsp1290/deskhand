import NIOHTTP1

enum HTTPRefusal: Error, Hashable, Sendable, CaseIterable {
    case headerTooLarge
    case notFound
    case methodNotAllowed
    case misdirected
    case originPresent
    case unauthorized
    case unsupportedMediaType
    case bodyTooLarge
    case notAcceptable

    var status: HTTPResponseStatus {
        switch self {
        case .headerTooLarge: .requestHeaderFieldsTooLarge
        case .notFound: .notFound
        case .methodNotAllowed: .methodNotAllowed
        case .misdirected: .misdirectedRequest
        case .originPresent: .forbidden
        case .unauthorized: .unauthorized
        case .unsupportedMediaType: .unsupportedMediaType
        case .bodyTooLarge: .payloadTooLarge
        case .notAcceptable: .notAcceptable
        }
    }

    var headers: [(String, String)] {
        switch self {
        case .methodNotAllowed: [("Allow", "POST")]
        case .unauthorized: [("WWW-Authenticate", #"Bearer realm="deskhand""#)]
        default: []
        }
    }
}

struct AdmittedHead {
    let version: HTTPVersion
    let keepAlive: Bool
    let headers: HTTPHeaders
    let declaredLength: Int?
}

struct RequestScreen: Sendable {
    let hosts: HostAllowlist
    let maxHeaderBytes: Int
    let maxBodyBytes: Int

    init(_ configuration: ListenerConfiguration) {
        hosts = configuration.hosts
        maxHeaderBytes = configuration.maxRequestHeaderBytes
        maxBodyBytes = configuration.maxRequestBodyBytes
    }

    init(hosts: HostAllowlist, maxHeaderBytes: Int, maxBodyBytes: Int) {
        self.hosts = hosts
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    func screenHead(
        _ head: HTTPRequestHead,
        tokens: AcceptedTokens,
        now: ContinuousClock.Instant
    ) -> Result<AdmittedHead, HTTPRefusal> {
        guard Self.headerBlockSize(head) <= maxHeaderBytes else { return .failure(.headerTooLarge) }
        guard head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first == "/mcp" else {
            return .failure(.notFound)
        }
        guard head.method == .POST else { return .failure(.methodNotAllowed) }
        let hostValues = head.headers["Host"]
        guard hostValues.count == 1, hosts.accepts(hostValues[0]) else { return .failure(.misdirected) }
        guard !head.headers.contains(name: "Origin") else { return .failure(.originPresent) }
        guard let token = Self.bearerToken(head.headers["Authorization"]), tokens.accepts(token.utf8, at: now) else {
            return .failure(.unauthorized)
        }
        guard Self.isJSONContentType(head.headers["Content-Type"]) else { return .failure(.unsupportedMediaType) }
        let lengths = head.headers["Content-Length"]
        let declaredLength = lengths.count == 1 ? Int(lengths[0]) : nil
        if let declaredLength, declaredLength > maxBodyBytes { return .failure(.bodyTooLarge) }
        return .success(
            AdmittedHead(
                version: head.version,
                keepAlive: head.isKeepAlive,
                headers: head.headers,
                declaredLength: declaredLength
            )
        )
    }

    func screenBody(byteCount: Int) -> HTTPRefusal? {
        byteCount > maxBodyBytes ? .bodyTooLarge : nil
    }

    func screenAccept(_ head: AdmittedHead) -> HTTPRefusal? {
        Self.acceptAdmitsJSON(head.headers["Accept"]) ? nil : .notAcceptable
    }

    static func headerBlockSize(_ head: HTTPRequestHead) -> Int {
        var size = head.method.rawValue.utf8.count + 1 + head.uri.utf8.count + 1 + "HTTP/1.1\r\n".utf8.count
        for (name, value) in head.headers { size += name.utf8.count + 2 + value.utf8.count + 2 }
        return size + 2
    }

    static func bearerToken(_ values: [String]) -> Substring? {
        guard values.count == 1, let space = values[0].firstIndex(of: " ") else { return nil }
        let value = values[0]
        guard value[..<space].lowercased() == "bearer" else { return nil }
        let token = value[space...].drop(while: { $0 == " " })
        guard !token.isEmpty, !token.contains(" ") else { return nil }
        return token
    }

    static func isJSONContentType(_ values: [String]) -> Bool {
        guard values.count == 1 else { return false }
        let parts = values[0].split(separator: ";", omittingEmptySubsequences: false).map(trimmed)
        guard parts[0].lowercased() == "application/json" else { return false }
        return parts.dropFirst().allSatisfy { parameter in
            let pair = parameter.split(separator: "=", maxSplits: 1).map(trimmed)
            guard pair.count == 2, pair[0].lowercased() == "charset" else { return false }
            let value =
                pair[1].hasPrefix("\"") && pair[1].hasSuffix("\"") && pair[1].count >= 2
                ? pair[1].dropFirst().dropLast() : pair[1]
            return value.lowercased() == "utf-8"
        }
    }

    static func acceptAdmitsJSON(_ values: [String]) -> Bool {
        guard !values.isEmpty else { return true }
        let ranges = values.flatMap { $0.split(separator: ",") }
        return ranges.contains { range in
            let parts = range.split(separator: ";").map(trimmed)
            guard let type = parts.first?.lowercased(), ["application/json", "application/*", "*/*"].contains(type)
            else { return false }
            let quality = parts.dropFirst().first { $0.lowercased().hasPrefix("q=") }.flatMap {
                Double($0.dropFirst(2))
            }
            return quality.map { $0 > 0 } ?? true
        }
    }

    private static func trimmed(_ text: Substring) -> Substring {
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        guard let first = text.firstIndex(where: { !isBlank($0) }), let last = text.lastIndex(where: { !isBlank($0) })
        else { return "" }
        return text[first...last]
    }
}
