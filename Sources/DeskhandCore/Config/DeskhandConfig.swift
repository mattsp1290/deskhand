/// One Mac's deskhand configuration, supplied by birbhomes. Only a validated document produces a
/// value: build it with ``init(parsing:)``, ``init(json:)`` or ``load(fromFile:)``.
///
/// The file is one I-JSON object (duplicate member names are refused). Every object is closed:
/// an unknown member is an error, never ignored. Members marked optional take the default shown.
///
/// ```text
/// {
///   "version": 1,                                  required, the integer 1
///   "mac": "lunus-macbook-pro",                    required, 1-63 of a-z 0-9 - (status.mac, allowance mac)
///   "listen": {                                    required
///     "address": "10.0.0.149",                     IPv4/IPv6 unicast LAN literal; never loopback,
///                                                  unspecified (0.0.0.0, ::), multicast, broadcast, link-local
///     "port": 8443                                 1-65535
///   },
///   "service": {                                   required: the accepted Host values (contract 2.3)
///     "names": ["deskhand-lunus-macbook-pro.forge.svc",
///               "deskhand-lunus-macbook-pro.forge.svc.cluster.local"],
///                                                  1-8 distinct lowercase DNS names, no IP literal
///     "port": 443                                  1-65535, the port callers dial on the Service
///   },
///   "credentials": {                               required; the paths absolute and pairwise distinct
///     "client_subject": "CN=crew-executor,O=crew", the expected client certificate subject, as the
///                                                  RFC 4514 string of its DER encoding (contract 2.2);
///                                                  1-1024 bytes, no NUL
///     "ca_certificate_path": "...",                private CA (PEM) for client and server chains
///     "server_certificate_path": "...",            server leaf certificate (PEM)
///     "server_key_path": "...",                    server private key (PEM)
///     "token_path": "...",                         per-Mac bearer token
///     "token_overlap_ms": 0                        optional, 0-3,600,000: how long a replaced token stays valid
///   },
///   "allowance": {                                 required (contract 14)
///     "path": "...",                               absolute, distinct from every credential path
///     "skew_tolerance_ms": 0,                      optional, 0-60,000 (ALLOWANCE_SKEW_TOLERANCE_MS)
///     "gated_ends_arming": true                    optional, default true (contract 10.4)
///   },
///   "app_policy": {                                optional, default {"allow": []} (deny everything)
///     "allow": [                                   0-256 distinct entries
///       {"bundle_id": "com.apple.TextEdit",        bundle identifier, compared exactly; one that
///                                                  the default deny list covers is an error, since
///                                                  the deny list wins and the entry could never allow
///        "team_id": null}                          10 of A-Z 0-9 (TeamID), or null for Apple-signed
///     ]
///   },
///   "limits": {                                    optional; members as in status.limits
///     "frame_max_age_ms": 60000,                   optional, 5,000-600,000
///     "actions_per_minute": 60,                    optional, 1-600
///     "operation_retention_ms": 86400000,          optional, 60,000-604,800,000
///     "operation_max_records": 10000               optional, 1-100,000
///   }
/// }
/// ```
///
/// Contract constants (request and text size, user-activity lookback, patch tolerance and the rest
/// of ``ContractConstants``) are fixed by the contract and cannot be configured.
public struct DeskhandConfig: Hashable, Sendable {
    public static let formatVersion = 1

    /// This Mac's name: `status.mac`, and what an allowance's `mac` must equal.
    public let mac: String
    public let listen: ListenConfig
    public let service: ServiceConfig
    public let credentials: CredentialsConfig
    public let allowance: AllowanceConfig
    /// The `app_policy.allow` entries, decoded into the policy's own ``AllowedApp``. Deny-by-default:
    /// an app not listed here is denied, and an absent `app_policy` or `allow` yields `[]`.
    public let allowedApps: [AllowedApp]
    /// The configured values that `status.limits` reports.
    public let limits: Limits

    /// The app policy this configuration describes, with deskhand's own bundle always denied.
    public func appPolicy(deskhandBundleID: BundleID) -> AppPolicy {
        AppPolicy(deskhandBundleID: deskhandBundleID, allowed: Set(allowedApps))
    }

    /// How states combine on this Mac.
    public var stateConfiguration: StateConfiguration {
        StateConfiguration(gatedEndsArming: allowance.gatedEndsArming)
    }
}

public struct ListenConfig: Hashable, Sendable {
    public let address: ListenAddress
    public let port: Int
}

/// What a request's `Host` header may name (contract 2.3).
public struct ServiceConfig: Hashable, Sendable {
    /// Lowercase, so a case-insensitive `Host` comparison only lowercases the header.
    public let names: [String]
    /// The port callers dial on the cluster Service, which can differ from ``ListenConfig/port``.
    public let port: Int
}

public struct CredentialsConfig: Hashable, Sendable {
    /// The only client certificate subject accepted at the handshake, and so the only principal.
    public let clientSubject: Principal
    public let caCertificatePath: String
    public let serverCertificatePath: String
    public let serverKeyPath: String
    public let tokenPath: String
    /// How long the previous token is still accepted after the token file changes (contract 11.1).
    public let tokenOverlapMs: Int
}

public struct AllowanceConfig: Hashable, Sendable {
    public let path: String
    /// `ALLOWANCE_SKEW_TOLERANCE_MS`: applies to `not_before` only (contract 14.3).
    public let skewToleranceMs: Int
    /// `gated_ends_arming` (contract 10.4).
    public let gatedEndsArming: Bool
}

/// Defaults and ranges of the configured values. Where the contract gives a range or default it
/// is used; the other bounds are deskhand's choice.
public enum ConfigLimits {
    public static let serviceNameCount = 1...8
    public static let port = 1...65_535
    public static let maxPathBytes = 1024
    public static let maxClientSubjectBytes = 1024
    public static let defaultGatedEndsArming = true
    public static let tokenOverlapMs = 0...3_600_000
    public static let defaultTokenOverlapMs = 0
    public static let allowanceSkewToleranceMs = 0...60_000
    public static let defaultAllowanceSkewToleranceMs = 0
    public static let allowedAppCount = 0...256
    public static let frameMaxAgeMs = ContractConstants.frameMaxAgeMsRange
    public static let actionsPerMinute = 1...600
    public static let operationRetentionMs = 60_000...604_800_000
    public static let operationMaxRecords = 1...100_000
}
