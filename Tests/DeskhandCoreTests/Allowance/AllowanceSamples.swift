import DeskhandCore
import Synchronization

enum AllowanceSample {
    static let mac = "lunus-macbook-pro"
    static let path = "/var/run/birbhomes/deskhand-allowance.json"
    /// 2026-11-14T15:00:00Z
    static let notBefore = Timestamp(millisecondsSinceEpoch: 1_794_668_400_000)
    /// 2026-11-14T15:02:00Z
    static let expiresAt = Timestamp(millisecondsSinceEpoch: 1_794_668_520_000)
    static let during = notBefore.adding(milliseconds: 60_000)

    static let rootDirectory = AllowanceFileStatus(kind: .directory, owner: 0, permissions: 0o755)
    static let rootFile = AllowanceFileStatus(kind: .regular, owner: 0, permissions: 0o644)

    static func json(
        version: String = "1", mac: String = "\"lunus-macbook-pro\"", notBefore: String = "\"2026-11-14T15:00:00Z\"",
        expiresAt: String = "\"2026-11-14T15:02:00Z\"", extra: String = ""
    ) -> String {
        """
        {"version": \(version), "mac": \(mac), "not_before": \(notBefore), "expires_at": \(expiresAt)\(extra)}
        """
    }

    static func opened(
        directory: AllowanceFileStatus = rootDirectory, file: AllowanceFileStatus = rootFile, contents: String = json()
    ) -> AllowanceProbe {
        .opened(directory: directory, file: file, contents: Array(contents.utf8))
    }

    static func reader(_ probe: some AllowanceFileProbe, skewToleranceMs: Int = 0) -> AllowanceReader {
        AllowanceReader(path: path, mac: mac, skewToleranceMs: skewToleranceMs, probe: probe)
    }

    static func reader(_ result: AllowanceProbe, skewToleranceMs: Int = 0) -> AllowanceReader {
        reader(FakeAllowanceProbe(result), skewToleranceMs: skewToleranceMs)
    }
}

/// Answers every probe with a settable result and records the calls.
final class FakeAllowanceProbe: AllowanceFileProbe {
    struct Call: Hashable {
        let directory: String
        let name: String
        let maxBytes: Int
    }

    private let state: Mutex<(result: AllowanceProbe, calls: [Call])>

    init(_ result: AllowanceProbe) { state = Mutex((result, [])) }

    var calls: [Call] { state.withLock { $0.calls } }

    func set(_ result: AllowanceProbe) { state.withLock { $0.result = result } }

    func probe(directory: String, name: String, maxBytes: Int) -> AllowanceProbe {
        state.withLock {
            $0.calls.append(Call(directory: directory, name: name, maxBytes: maxBytes))
            return $0.result
        }
    }
}
