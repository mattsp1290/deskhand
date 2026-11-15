import Foundation

public struct SessionClaim: Codable {
  public let ownerUUID: String
  public let artifactID: String
}

public enum SessionIdentity {
  public static func artifact(_ context: JSON) -> String {
    JSON.obj([
      ("receipt", context["build_receipt"].orNull),
      ("cdhash", context["cdhash"].orNull),
      ("path", context["bundle_path"].orNull),
    ]).compact()
  }

  public static func verifyReplacement(previous: JSON, replacement: JSON) throws {
    guard let oldInstance = previous["process_instance"]?.stringValue,
      let newInstance = replacement["process_instance"]?.stringValue,
      oldInstance != newInstance,
      let oldPID = previous["pid"]?.intValue, oldPID > 0,
      let newPID = replacement["pid"]?.intValue, newPID > 0, oldPID != newPID,
      replacement["launched_by"]?.stringValue == "launch_agent",
      previous["cdhash"]?.stringValue != nil, previous["build_receipt"]?.members != nil,
      previous["bundle_path"]?.stringValue != nil,
      artifact(previous) == artifact(replacement)
    else {
      throw TrialAbort.failed("replacement process or artifact identity mismatch")
    }
  }
}

@MainActor public final class MeasurementSession {
  private var claim: SessionClaim?
  private var busy = false
  private var suspended = false
  private let file: URL?
  private let artifactID: String
  public private(set) var error: String?

  public init(file: URL? = nil, artifactID: String = "in-memory") {
    self.file = file
    self.artifactID = artifactID
    guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
    suspended = true
    do {
      let restored = try JSONDecoder().decode(SessionClaim.self, from: Data(contentsOf: file))
      guard UUID(uuidString: restored.ownerUUID) != nil else {
        throw TrialAbort.failed("invalid claim owner")
      }
      claim = restored
    } catch { self.error = "invalid durable session claim: \(error)" }
  }

  public var isIdle: Bool { claim == nil && !busy && !suspended }

  public func begin(_ token: String) -> Bool {
    guard isIdle, UUID(uuidString: token) != nil else { return false }
    let next = SessionClaim(ownerUUID: token, artifactID: artifactID)
    do {
      if let file {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
      claim = next
      return true
    } catch {
      self.error = "claim persistence failed: \(error)"
      suspended = true
      return false
    }
  }

  public func resume(_ token: String) -> Bool {
    guard !busy, error == nil, claim?.ownerUUID == token, claim?.artifactID == artifactID else {
      return false
    }
    suspended = false
    return true
  }

  public func end(_ token: String) -> Bool {
    guard claim?.ownerUUID == token, claim?.artifactID == artifactID, !busy else { return false }
    do {
      if let file { try FileManager.default.removeItem(at: file) }
      claim = nil
      suspended = false
      error = nil
      return true
    } catch {
      self.error = "claim release failed: \(error)"
      return false
    }
  }

  public func enter(_ token: String?) -> Bool {
    guard !busy, !suspended, claim?.ownerUUID == token else { return false }
    busy = true
    return true
  }

  public func leave() { busy = false }
}
