import DeskhandCore

/// Configuration documents for tests. Kept as Swift strings because a `.json` file in the test
/// target would need a Package.swift `resources` or `exclude` entry. Test-only: the paths name no
/// real credentials.
enum ConfigFixtures {
    /// A complete configuration for `lunus-macbook-pro`, every optional member spelled out.
    static let example = """
        {
          "version": 1,
          "mac": "lunus-macbook-pro",
          "listen": { "address": "10.0.0.149", "port": 8443 },
          "service": {
            "names": [
              "deskhand-lunus-macbook-pro.forge.svc",
              "deskhand-lunus-macbook-pro.forge.svc.cluster.local"
            ],
            "port": 443
          },
          "credentials": {
            "client_subject": "CN=crew-executor,O=crew",
            "ca_certificate_path": "/Users/deskhand/Library/Application Support/deskhand/ca.pem",
            "server_certificate_path": "/Users/deskhand/Library/Application Support/deskhand/server.pem",
            "server_key_path": "/Users/deskhand/Library/Application Support/deskhand/server-key.pem",
            "token_path": "/Users/deskhand/Library/Application Support/deskhand/token",
            "token_overlap_ms": 0
          },
          "allowance": {
            "path": "/var/run/birbhomes/deskhand-allowance.json",
            "skew_tolerance_ms": 0,
            "gated_ends_arming": true
          },
          "app_policy": {
            "allow": [
              { "bundle_id": "com.apple.TextEdit", "team_id": null },
              { "bundle_id": "com.example.Editor", "team_id": "ABCDE12345" }
            ]
          },
          "limits": {
            "frame_max_age_ms": 60000,
            "actions_per_minute": 60,
            "operation_retention_ms": 86400000,
            "operation_max_records": 10000
          }
        }
        """

    /// The required members only, for `m1max2021`.
    static let minimal: JSONValue = [
        "version": 1,
        "mac": "m1max2021",
        "listen": ["address": "10.0.0.96", "port": 8443],
        "service": ["names": ["deskhand-m1max2021.forge.svc"], "port": 8443],
        "credentials": [
            "client_subject": "CN=crew-executor,O=crew",
            "ca_certificate_path": "/etc/deskhand/ca.pem",
            "server_certificate_path": "/etc/deskhand/server.pem",
            "server_key_path": "/etc/deskhand/server-key.pem",
            "token_path": "/etc/deskhand/token",
        ],
        "allowance": ["path": "/var/run/birbhomes/allowance.json"],
    ]

    /// `minimal` with the value at `path` replaced, or removed when `value` is `nil`.
    static func minimal(setting path: [String], to value: JSONValue?) -> JSONValue {
        setting(minimal, path, to: value)
    }

    /// `document` with the value at `path` replaced, or removed when `value` is `nil`. Missing
    /// objects along the path are created.
    static func setting(_ document: JSONValue, _ path: [String], to value: JSONValue?) -> JSONValue {
        setting(document, path[...], to: value)
    }

    private static func setting(_ document: JSONValue, _ path: ArraySlice<String>, to value: JSONValue?) -> JSONValue {
        guard let key = path.first else { return value ?? .null }
        switch document {
        case .object(var members):
            if path.count == 1 {
                members[key] = value
            } else {
                members[key] = setting(members[key] ?? .object([:]), path.dropFirst(), to: value)
            }
            return .object(members)
        case .array(var items):
            let index = Int(key)!
            items[index] = setting(items[index], path.dropFirst(), to: value)
            return .array(items)
        default:
            preconditionFailure("cannot descend into \(document) at \(key)")
        }
    }
}
