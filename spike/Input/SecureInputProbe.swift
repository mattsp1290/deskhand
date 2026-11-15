import AppKit
import Carbon.HIToolbox
import Foundation
import SpikeKit

enum SecureInputProbe {
  static let spec = ProbeSpec(
    name: "input-secure", items: ["6"],
    summary: "secure input with the harness's own secure field; posted keys into it",
    run: run)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("input-secure", items: spec.items)
    guard InputGuard.begin(&report) else { return report }
    report.set("before", Signals.secureInput())
    let rig = InputRig(width: 420, height: 160)
    let secure = NSSecureTextField(frame: NSRect(x: 20, y: 20, width: 380, height: 28))
    let plain = NSTextField(frame: NSRect(x: 20, y: 100, width: 380, height: 28))
    rig.window.view.addSubview(secure)
    rig.window.view.addSubview(plain)
    await rig.show()
    let focused = await rig.focus()
    report.set("harness_owns_keyboard", .bool(focused))
    guard focused else {
      report.skip("the harness could not become frontmost with its window key")
      await rig.tearDown()
      return report
    }

    rig.window.makeFirstResponder(secure)
    await settle(ms: 300)
    let secureFocused = Signals.secureInput()
    await Post.type("xyz")
    await settle(ms: 300)
    let secureReceived = secure.stringValue.count

    rig.window.makeFirstResponder(plain)
    await settle(ms: 300)
    let plainFocused = Signals.secureInput()
    await Post.type("xyz")
    await settle(ms: 300)
    let plainReceived = plain.stringValue.count

    plain.stringValue = ""
    EnableSecureEventInput()
    await settle(ms: 200)
    let explicit = Signals.secureInput()
    await Post.type("xyz")
    await settle(ms: 300)
    let explicitReceived = plain.stringValue.count
    DisableSecureEventInput()
    await settle(ms: 200)
    let after = Signals.secureInput()
    secure.stringValue = ""
    plain.stringValue = ""
    await rig.tearDown()

    report.set(
      "own_secure_field",
      .obj([
        ("secure_input", secureFocused), ("posted", .int(3)), ("received", .int(secureReceived)),
      ]))
    report.set(
      "own_plain_field",
      .obj([("secure_input", plainFocused), ("posted", .int(3)), ("received", .int(plainReceived))])
    )
    report.set(
      "own_plain_field_with_enable_secure_event_input",
      .obj([("secure_input", explicit), ("posted", .int(3)), ("received", .int(explicitReceived))]))
    report.set("after", after)
    func on(_ json: JSON) -> String { json["enabled"]?.boolValue == true ? "on" : "off" }
    report.finding(
      "own secure field focused: secure input \(on(secureFocused)) (pid "
        + "\(secureFocused["session_secure_input_pid"]?.intValue.map(String.init) ?? "none")), "
        + "posted keys received \(secureReceived)/3")
    report.finding(
      "own plain field: secure input \(on(plainFocused)), received \(plainReceived)/3; with "
        + "EnableSecureEventInput: secure input \(on(explicit)), received \(explicitReceived)/3")
    report.needsHuman = true
    report.note(
      "other apps' password fields, auth prompts and the unlock screen: trial secure-input")
    return report
  }
}
