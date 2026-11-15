import Foundation

@MainActor public final class MeasurementSession {
  private var owner: String?
  private var busy = false

  public init() {}
  public var isIdle: Bool { owner == nil && !busy }

  public func begin(_ token: String) -> Bool {
    guard isIdle, UUID(uuidString: token) != nil else { return false }
    owner = token
    return true
  }

  public func end(_ token: String) -> Bool {
    guard owner == token, !busy else { return false }
    owner = nil
    return true
  }

  public func enter(_ token: String?) -> Bool {
    guard !busy, owner == token else { return false }
    busy = true
    return true
  }

  public func leave() { busy = false }
}
