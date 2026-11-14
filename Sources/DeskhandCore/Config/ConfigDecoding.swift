import Foundation

extension DeskhandConfig {
    /// Configuration files larger than this are refused before parsing.
    public static let maxFileBytes = 1_048_576

    /// Parses and validates one configuration document.
    public init(parsing bytes: some Collection<UInt8>) throws(ConfigError) {
        let json: JSONValue
        do {
            json = try JSONValue(parsing: bytes)
        } catch {
            throw .notJSON(error)
        }
        try self.init(json: json)
    }

    /// Validates an already parsed document and reports every issue found, not only the first.
    public init(json: JSONValue) throws(ConfigError) {
        var reader = ConfigReader()
        let config = reader.config(json)
        guard let config, reader.issues.isEmpty else { throw .invalid(reader.issues) }
        self = config
    }

    /// Reads and validates the configuration file at `path`.
    public static func load(fromFile path: String) throws(ConfigError) -> DeskhandConfig {
        let bytes: Data
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            bytes = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        } catch {
            throw .unreadable(path: path, reason: String(describing: error))
        }
        guard bytes.count <= maxFileBytes else { throw .tooLarge(path: path, maxBytes: maxFileBytes) }
        return try DeskhandConfig(parsing: bytes)
    }
}

/// Walks a configuration document, collecting every issue. Each method returns `nil` when the
/// value it reads is unusable, after recording why.
private struct ConfigReader {
    private(set) var issues: [ConfigIssue] = []

    private mutating func report(_ pointer: JSONPointer, _ rule: ConfigRule) {
        issues.append(ConfigIssue(pointer, rule))
    }

    mutating func config(_ json: JSONValue) -> DeskhandConfig? {
        let root = JSONPointer.root
        guard
            let members = closedObject(
                json, at: root, required: ["version", "mac", "listen", "service", "credentials", "allowance"],
                optional: ["app_policy", "limits"])
        else { return nil }

        if let version = members["version"], version != JSONValue(DeskhandConfig.formatVersion) {
            report(root.appending("version"), .version(DeskhandConfig.formatVersion))
        }
        let mac = members["mac"].flatMap { macName($0, at: root.appending("mac")) }
        let listen = members["listen"].flatMap { readListen($0, at: root.appending("listen")) }
        let service = members["service"].flatMap { readService($0, at: root.appending("service")) }
        let credentials = members["credentials"].flatMap { readCredentials($0, at: root.appending("credentials")) }
        let allowance = members["allowance"].flatMap { readAllowance($0, at: root.appending("allowance")) }
        let allowedApps = members["app_policy"].map { readAppPolicy($0, at: root.appending("app_policy")) } ?? []
        let limits = members["limits"].map { readLimits($0, at: root.appending("limits")) } ?? Limits()

        if let credentials, let allowance {
            requireDistinctPaths(credentials: credentials, allowance: allowance)
        }
        guard let mac, let listen, let service, let credentials, let allowance, let allowedApps, let limits else {
            return nil
        }
        return DeskhandConfig(
            mac: mac, listen: listen, service: service, credentials: credentials, allowance: allowance,
            allowedApps: allowedApps, limits: limits)
    }

    // MARK: Sections

    private mutating func readListen(_ value: JSONValue, at path: JSONPointer) -> ListenConfig? {
        guard let members = closedObject(value, at: path, required: ["address", "port"]) else { return nil }
        let address = members["address"].flatMap { listenAddress($0, at: path.appending("address")) }
        let port = members["port"].flatMap { integer($0, at: path.appending("port"), in: ConfigLimits.port) }
        guard let address, let port else { return nil }
        return ListenConfig(address: address, port: port)
    }

    private mutating func readService(_ value: JSONValue, at path: JSONPointer) -> ServiceConfig? {
        guard let members = closedObject(value, at: path, required: ["names", "port"]) else { return nil }
        let names = members["names"].flatMap {
            uniqueArray($0, at: path.appending("names"), count: ConfigLimits.serviceNameCount) { reader, value, path in
                reader.dnsName(value, at: path)
            }
        }
        let port = members["port"].flatMap { integer($0, at: path.appending("port"), in: ConfigLimits.port) }
        guard let names, let port else { return nil }
        return ServiceConfig(names: names, port: port)
    }

    private mutating func readCredentials(_ value: JSONValue, at path: JSONPointer) -> CredentialsConfig? {
        guard
            let members = closedObject(
                value, at: path,
                required: ["ca_certificate_path", "server_certificate_path", "server_key_path", "token_path"],
                optional: ["token_overlap_ms"])
        else { return nil }
        let ca = members["ca_certificate_path"].flatMap { absolutePath($0, at: path.appending("ca_certificate_path")) }
        let certificate = members["server_certificate_path"].flatMap {
            absolutePath($0, at: path.appending("server_certificate_path"))
        }
        let key = members["server_key_path"].flatMap { absolutePath($0, at: path.appending("server_key_path")) }
        let token = members["token_path"].flatMap { absolutePath($0, at: path.appending("token_path")) }
        let overlap = optionalInteger(
            members["token_overlap_ms"], at: path.appending("token_overlap_ms"), in: ConfigLimits.tokenOverlapMs,
            default: ConfigLimits.defaultTokenOverlapMs)
        guard let ca, let certificate, let key, let token, let overlap else { return nil }
        return CredentialsConfig(
            caCertificatePath: ca, serverCertificatePath: certificate, serverKeyPath: key, tokenPath: token,
            tokenOverlapMs: overlap)
    }

    private mutating func readAllowance(_ value: JSONValue, at path: JSONPointer) -> AllowanceConfig? {
        guard let members = closedObject(value, at: path, required: ["path"], optional: ["skew_tolerance_ms"]) else {
            return nil
        }
        let filePath = members["path"].flatMap { absolutePath($0, at: path.appending("path")) }
        let skew = optionalInteger(
            members["skew_tolerance_ms"], at: path.appending("skew_tolerance_ms"),
            in: ConfigLimits.allowanceSkewToleranceMs, default: ConfigLimits.defaultAllowanceSkewToleranceMs)
        guard let filePath, let skew else { return nil }
        return AllowanceConfig(path: filePath, skewToleranceMs: skew)
    }

    private mutating func readAppPolicy(_ value: JSONValue, at path: JSONPointer) -> [AllowedApp]? {
        guard let members = closedObject(value, at: path, required: [], optional: ["allow"]) else { return nil }
        guard let allow = members["allow"] else { return [] }
        return uniqueArray(allow, at: path.appending("allow"), count: ConfigLimits.allowedAppCount) {
            reader, value, path in reader.allowedApp(value, at: path)
        }
    }

    private mutating func allowedApp(_ value: JSONValue, at path: JSONPointer) -> AllowedApp? {
        guard let members = closedObject(value, at: path, required: ["bundle_id", "team_id"]) else { return nil }
        let bundleID = members["bundle_id"].flatMap { value -> BundleID? in
            guard let id = string(value, at: path.appending("bundle_id")).flatMap(BundleID.init) else {
                if case .string = value { report(path.appending("bundle_id"), .bundleID) }
                return nil
            }
            return id
        }
        // `null` means a signature with no team identifier, which the policy trusts only as Apple's.
        var signer: TrustedSigner?
        switch members["team_id"] {
        case .some(.null): signer = .apple
        case .some(.string(let text)):
            if let team = TeamID(text) { signer = .team(team) } else { report(path.appending("team_id"), .teamID) }
        case .some: report(path.appending("team_id"), .teamID)
        case nil: break
        }
        guard let bundleID, let signer else { return nil }
        return AllowedApp(bundleID: bundleID, signer: signer)
    }

    private mutating func readLimits(_ value: JSONValue, at path: JSONPointer) -> Limits? {
        guard
            let members = closedObject(
                value, at: path, required: [],
                optional: ["frame_max_age_ms", "actions_per_minute", "operation_retention_ms", "operation_max_records"])
        else { return nil }
        let defaults = Limits()
        let frameMaxAge = optionalInteger(
            members["frame_max_age_ms"], at: path.appending("frame_max_age_ms"), in: ConfigLimits.frameMaxAgeMs,
            default: defaults.frameMaxAgeMs)
        let actions = optionalInteger(
            members["actions_per_minute"], at: path.appending("actions_per_minute"),
            in: ConfigLimits.actionsPerMinute, default: defaults.actionsPerMinute)
        let retention = optionalInteger(
            members["operation_retention_ms"], at: path.appending("operation_retention_ms"),
            in: ConfigLimits.operationRetentionMs, default: defaults.operationRetentionMs)
        let maxRecords = optionalInteger(
            members["operation_max_records"], at: path.appending("operation_max_records"),
            in: ConfigLimits.operationMaxRecords, default: defaults.operationMaxRecords)
        guard let frameMaxAge, let actions, let retention, let maxRecords else { return nil }
        return Limits(
            frameMaxAgeMs: frameMaxAge, actionsPerMinute: actions, operationRetentionMs: retention,
            operationMaxRecords: maxRecords)
    }

    /// The four credential files and the allowance must be five different files: a token path that
    /// equals the key path, say, would publish one credential under another's name.
    private mutating func requireDistinctPaths(credentials: CredentialsConfig, allowance: AllowanceConfig) {
        let credentialsPath = JSONPointer.root.appending("credentials")
        let paths: [(JSONPointer, String)] = [
            (credentialsPath.appending("ca_certificate_path"), credentials.caCertificatePath),
            (credentialsPath.appending("server_certificate_path"), credentials.serverCertificatePath),
            (credentialsPath.appending("server_key_path"), credentials.serverKeyPath),
            (credentialsPath.appending("token_path"), credentials.tokenPath),
            (JSONPointer.root.appending("allowance").appending("path"), allowance.path),
        ]
        var firstUse: [String: JSONPointer] = [:]
        for (pointer, path) in paths {
            if let earlier = firstUse[path] {
                report(pointer, .distinctPath(from: earlier))
            } else {
                firstUse[path] = pointer
            }
        }
    }

    // MARK: Values

    /// The object's members, after reporting each unknown member and each missing required one.
    /// Returns the members even when some are missing, so the present ones are still checked.
    private mutating func closedObject(
        _ value: JSONValue, at path: JSONPointer, required: [String], optional: [String] = []
    ) -> JSONObject? {
        guard case .object(let members) = value else {
            report(path, .object)
            return nil
        }
        let known = Set(required + optional)
        for name in members.keys.sorted() where !known.contains(name) {
            report(path.appending(name), .unknownMember)
        }
        for name in required where members[name] == nil {
            report(path.appending(name), .missingMember)
        }
        return members
    }

    private mutating func string(_ value: JSONValue, at path: JSONPointer) -> String? {
        guard case .string(let text) = value else {
            report(path, .string)
            return nil
        }
        return text
    }

    /// A JSON number with no fraction inside `range`.
    private mutating func integer(_ value: JSONValue, at path: JSONPointer, in range: ClosedRange<Int>) -> Int? {
        guard case .number(let number) = value, number.rounded(.towardZero) == number,
            Double(range.lowerBound) <= number, number <= Double(range.upperBound)
        else {
            report(path, .integer(range))
            return nil
        }
        return Int(number)
    }

    private mutating func optionalInteger(
        _ value: JSONValue?, at path: JSONPointer, in range: ClosedRange<Int>, default fallback: Int
    ) -> Int? {
        guard let value else { return fallback }
        return integer(value, at: path, in: range)
    }

    private mutating func uniqueArray<T: Hashable>(
        _ value: JSONValue, at path: JSONPointer, count: ClosedRange<Int>,
        _ element: (inout ConfigReader, JSONValue, JSONPointer) -> T?
    ) -> [T]? {
        guard case .array(let items) = value, count.contains(items.count) else {
            report(path, .array(count: count))
            return nil
        }
        var firstAt: [T: JSONPointer] = [:]
        var decoded: [T] = []
        var complete = true
        for (index, item) in items.enumerated() {
            let itemPath = path.appending(index)
            guard let member = element(&self, item, itemPath) else {
                complete = false
                continue
            }
            if let first = firstAt[member] {
                report(itemPath, .unique(firstAt: first))
                complete = false
            } else {
                firstAt[member] = itemPath
                decoded.append(member)
            }
        }
        return complete ? decoded : nil
    }

    private mutating func macName(_ value: JSONValue, at path: JSONPointer) -> String? {
        guard let text = string(value, at: path) else { return nil }
        let valid =
            (1...63).contains(text.utf8.count)
            && text.utf8.allSatisfy { Self.isLowerAlphanumeric($0) || $0 == UInt8(ascii: "-") }
        guard valid else {
            report(path, .macName)
            return nil
        }
        return text
    }

    private mutating func listenAddress(_ value: JSONValue, at path: JSONPointer) -> ListenAddress? {
        guard let text = string(value, at: path) else { return nil }
        do {
            return try ListenAddress(text)
        } catch {
            report(path, .listenAddress(error))
            return nil
        }
    }

    private mutating func dnsName(_ value: JSONValue, at path: JSONPointer) -> String? {
        guard let text = string(value, at: path) else { return nil }
        guard Self.isDNSName(text) else {
            report(path, .dnsName)
            return nil
        }
        return text
    }

    private mutating func absolutePath(_ value: JSONValue, at path: JSONPointer) -> String? {
        guard let text = string(value, at: path) else { return nil }
        let bytes = text.utf8
        guard bytes.first == UInt8(ascii: "/"), bytes.count <= ConfigLimits.maxPathBytes, !bytes.contains(0) else {
            report(path, .absolutePath)
            return nil
        }
        return text
    }

    // MARK: Character rules

    private static func isLowerAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// RFC 1123 host name in lowercase. A last label of digits only is refused (RFC 3696 section 2),
    /// which also refuses every dotted-quad IPv4 literal.
    static func isDNSName(_ text: String) -> Bool {
        guard (1...253).contains(text.utf8.count) else { return false }
        let labels = text.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        let labelsValid = labels.allSatisfy { label in
            (1...63).contains(label.count) && label.first != UInt8(ascii: "-") && label.last != UInt8(ascii: "-")
                && label.allSatisfy { isLowerAlphanumeric($0) || $0 == UInt8(ascii: "-") }
        }
        let lastIsNumeric = labels.last?.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } ?? true
        return labelsValid && !lastIsNumeric
    }
}
