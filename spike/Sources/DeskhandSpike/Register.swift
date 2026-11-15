import Foundation
import ServiceManagement
import SpikeKit

enum Register {
  static var plistName: String {
    (Bundle.main.bundleIdentifier ?? RunContext.bundleIdentifier) + ".agent.plist"
  }

  static func statusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "not_registered"
    case .enabled: "enabled"
    case .requiresApproval: "requires_approval"
    case .notFound: "not_found"
    @unknown default: "unknown(\(status.rawValue))"
    }
  }

  static func run(_ command: String) async -> (JSON, Int32) {
    let service = SMAppService.agent(plistName: plistName)
    var result: [(String, JSON)] = [
      ("command", .string(command)), ("bundle_path", .string(Bundle.main.bundlePath)),
      ("status_before", .string(statusName(service.status))),
    ]
    var code: Int32 = 0
    switch command {
    case "register":
      if service.status == .enabled { break }
      do {
        try service.register()
      } catch {
        result.append(("error", .string("\(error)")))
        code = 1
      }
    case "unregister":
      do {
        try await service.unregister()
      } catch {
        result.append(("error", .string("\(error)")))
        if service.status != .notRegistered { code = 1 }
      }
    case "status":
      break
    default:
      result.append(("error", .string("unknown command")))
      code = 2
    }
    let status = service.status
    result.append(("status", .string(statusName(status))))
    if status == .requiresApproval {
      result.append(
        ("hint", .string("approve deskhand-spike in System Settings > General > Login Items")))
      if command == "register" {
        SMAppService.openSystemSettingsLoginItems()
        code = 4
      }
    }
    return (.obj(result), code)
  }
}
