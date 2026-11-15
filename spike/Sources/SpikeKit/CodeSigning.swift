import Foundation
import Security

/// Code-signing facts for a running process, read with the Security framework. Used for the
/// harness's own identity (TCC grants follow the designated requirement) and for the identity
/// questions on deskhand-7t13 (Apple platform binaries, Mac App Store apps, team anchors).
public nonisolated enum CodeSigning {
  /// Requirements evaluated against every measured process.
  public static let requirementChecks: [(String, String)] = [
    ("anchor_apple", "anchor apple"),
    ("anchor_apple_generic", "anchor apple generic"),
    (
      "mac_app_store_leaf",
      "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
    ),
    (
      "developer_id_leaf",
      "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    ),
  ]

  public static func facts(pid: pid_t) -> JSON {
    var guest: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
    guard status == errSecSuccess, let code = guest else {
      return .obj([("error", .string("SecCodeCopyGuestWithAttributes \(status)"))])
    }
    return facts(code: code)
  }

  public static func selfFacts() -> JSON {
    var me: SecCode?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me else {
      return .obj([("error", .string("SecCodeCopySelf failed"))])
    }
    return facts(code: me)
  }

  public static func facts(code: SecCode) -> JSON {
    var staticCode: SecStaticCode?
    var status = SecCodeCopyStaticCode(code, [], &staticCode)
    guard status == errSecSuccess, let staticCode else {
      return .obj([("error", .string("SecCodeCopyStaticCode \(status)"))])
    }
    var rawInfo: CFDictionary?
    status = SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation),
      &rawInfo)
    guard status == errSecSuccess, let info = rawInfo as? [String: Any] else {
      return .obj([("error", .string("SecCodeCopySigningInformation \(status)"))])
    }
    let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    let plist = info[kSecCodeInfoPList as String] as? [String: Any]
    let team = info[kSecCodeInfoTeamIdentifier as String] as? String
    let certificates = (info[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
    var path: CFURL?
    _ = SecCodeCopyPath(staticCode, [], &path)

    var designated: SecRequirement?
    var designatedText: CFString?
    if SecCodeCopyDesignatedRequirement(staticCode, [], &designated) == errSecSuccess,
      let designated
    {
      _ = SecRequirementCopyString(designated, [], &designatedText)
    }
    let validity: String
    switch designated.map({ SecCodeCheckValidity(code, [], $0) }) ?? errSecCSUnsigned {
    case errSecSuccess: validity = "valid"
    case errSecCSUnsigned: validity = "unsigned"
    case let other: validity = "invalid(\(other))"
    }

    var checks: [(String, JSON)] = requirementChecks.map { name, text in
      (name, .bool(satisfies(code, text)))
    }
    if let team {
      let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
      checks.append(("team_anchor_leaf_ou", .bool(satisfies(code, text))))
    }
    let leafName = certificates.first.flatMap { certificate -> String? in
      var name: CFString?
      return SecCertificateCopyCommonName(certificate, &name) == errSecSuccess
        ? name as String? : nil
    }
    let bundlePath = (path as URL?)?.path
    let receipt = bundlePath.map { path in
      FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
    }
    return .obj([
      ("identifier", .str(info[kSecCodeInfoIdentifier as String] as? String)),
      ("bundle_id", .str(plist?[kCFBundleIdentifierKey as String] as? String)),
      ("team_id", .str(team)),
      ("validity", .string(validity)),
      ("adhoc", .bool(flags & SecCodeSignatureFlags.adhoc.rawValue != 0)),
      ("hardened_runtime", .bool(flags & SecCodeSignatureFlags.runtime.rawValue != 0)),
      ("platform_identifier", .from(foundation: info[kSecCodeInfoPlatformIdentifier as String])),
      ("leaf_common_name", .str(leafName)),
      ("certificate_count", .int(certificates.count)),
      ("designated_requirement", .str(designatedText as String?)),
      ("requirements", .obj(checks)),
      ("path", .str(bundlePath)),
      ("mas_receipt_present", .bool(receipt)),
      ("cdhash_present", .bool(info[kSecCodeInfoUnique as String] != nil)),
      (
        "cdhash",
        .str(
          (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        )
      ),
    ])
  }

  static func satisfies(_ code: SecCode, _ text: String) -> Bool {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
  }
}
