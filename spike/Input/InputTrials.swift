import AppKit
import Foundation
import SpikeKit

/// Guided input trials. The harness never asks for, types or stores a password: it types only
/// the literal "xyz", and the person cancels every prompt.
enum InputTrials {
  // MARK: Item 6

  static let secureInput = TrialSpec(
    name: "secure-input", items: ["6"], effort: 5,
    summary: "posted keys vs secure input in an auth prompt, a System Settings field and the unlock screen",
    humanActions: "click into 2 password fields, say whether dots appeared, cancel; unlock once",
    run: { env in
      env.step(
        "Secure input. The harness types only the letters 'xyz'. Never type your password for "
          + "this trial; cancel every prompt.")
      let own = await env.call(["probe", "input-secure"]).last.orNull
      env.record(.obj([("target", .string("harness_secure_field")), ("probe", own)]))

      // A system authentication prompt (SecurityAgent).
      env.step("An administrator prompt will appear. Click into its password field within 8 seconds; do not type.")
      await env.waitEnter("Ready")
      let prompt = await env.act("auth-prompt")
      await Clock.sleep(ms: 8000)
      let before = await env.sample()
      let typed = await env.act("type-harmless")
      let dots = await env.ask("auth_prompt_dots", "Did three dots appear in the prompt's password field?")
      env.say("Click Cancel on the prompt now.")
      await Clock.sleep(ms: 3000)
      _ = await env.act("dismiss-auth-prompt")
      env.record(
        .obj([
          ("target", .string("system_auth_prompt")), ("prompt", prompt), ("before", before),
          ("typed", typed), ("dots_seen", .string(dots)),
        ]))

      // A password field in System Settings.
      _ = await env.act("open-settings", "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension")
      env.step(
        "In System Settings, open any password field (for example Touch ID & Password > Add "
          + "Fingerprint asks for your password) and click into it; do not type. You have 15 seconds "
          + "after pressing Enter.")
      await env.waitEnter("Ready")
      await Clock.sleep(ms: 15_000)
      let settingsBefore = await env.sample()
      let settingsTyped = await env.act("type-harmless")
      let settingsDots = await env.ask(
        "settings_dots", "Did three dots appear in that password field?", choices: ["y", "n", "no field"])
      env.say("Cancel that sheet now.")
      env.record(
        .obj([
          ("target", .string("system_settings_password_field")), ("before", settingsBefore),
          ("typed", settingsTyped), ("dots_seen", .string(settingsDots)),
        ]))

      // The unlock screen.
      env.step(
        "The harness will lock the screen and type 'xyz' at the lock screen. Look at the "
          + "password field, then unlock with Touch ID (clear the field first if you would type).")
      await env.waitEnter("Ready")
      _ = await env.act("lock-shortcut")
      _ = await env.poll(everyMs: 250, timeoutMs: 15_000) { sample in
        sample["lock"]?["session_screen_is_locked"]?.boolValue == true
      }
      await Clock.sleep(ms: 2000)
      let lockBefore = await env.sample()
      let lockTyped = await env.act("type-harmless")
      _ = await env.poll(everyMs: 500, timeoutMs: 600_000) { sample in
        sample["lock"]?["session_screen_is_locked"]?.boolValue == false
      }
      let lockDots = await env.ask(
        "unlock_screen_dots", "Before you unlocked, did the lock screen's password field show three dots?")
      env.record(
        .obj([
          ("target", .string("unlock_screen")), ("before", lockBefore), ("typed", lockTyped),
          ("dots_seen", .string(lockDots)),
        ]))

      func secure(_ sample: JSON) -> String {
        let s = sample["secure_input"]
        return "\(s?["enabled"]?.boolValue == true ? "on" : "off") (pid \(s?["session_secure_input_pid"]?.intValue.map(String.init) ?? "none"))"
      }
      env.report.finding("auth prompt: secure input \(secure(before)), xyz appeared: \(dots)")
      env.report.finding("System Settings field: secure input \(secure(settingsBefore)), xyz appeared: \(settingsDots)")
      env.report.finding("unlock screen: secure input \(secure(lockBefore)), xyz appeared: \(lockDots)")
      for finding in own["findings"]?.arrayValue ?? [] {
        env.report.finding("harness field: \(finding.stringValue ?? "")")
      }
      env.finish()
    })

  // MARK: deskhand-7t13 (b)

  static let dragOwner = TrialSpec(
    name: "drag-owner", items: ["7t13-b"], effort: 2,
    summary: "owner of the drag-image window during a real Finder drag",
    humanActions: "drag a file around in Finder for 6 seconds",
    run: { env in
      env.step(
        "After Enter, start dragging any file in a Finder window and keep moving it for about 6 "
          + "seconds, then drop it back where it was (or press Escape while dragging).")
      await env.waitEnter("Ready")
      var samples: [JSON] = []
      let end = Clock.monoMs() + 8000
      while Clock.monoMs() < end {
        samples.append(DragOwner.sample(at: Post.location()))
        await Clock.sleep(ms: 100)
      }
      let owners = DragOwner.owners(samples)
      env.record(.obj([("samples", .int(samples.count)), ("drag_level_owners", owners)]))
      let names = (owners.arrayValue ?? []).map {
        "\($0["owner_name"]?.stringValue ?? "?") (\($0["identifier"]?.stringValue ?? "?"), layer \($0["layer"]?.intValue ?? 0))"
      }
      env.report.finding(
        "real Finder drag: drag-level window owners: " + (names.isEmpty ? "none seen" : names.joined(separator: "; ")))
      env.finish()
    })
}

/// What SpikeInput adds to the harness.
public enum InputCatalog {
  public static var probes: [ProbeSpec] {
    [
      PostProbe.spec, IdleProbe.spec, SecureInputProbe.spec, HotKeyProbe.spec, HeldInputProbe.spec,
      FocusProbe.spec, ClickThroughProbe.spec, DragOwnerProbe.spec,
    ]
  }

  public static var trials: [TrialSpec] { [InputTrials.secureInput, InputTrials.dragOwner] }

  /// The internal subcommand the held-input probe runs as its child.
  public static let childCommand = "input-child"

  public static func runChild(_ arguments: [String]) async -> Int32 {
    await HeldInputProbe.child(arguments)
  }
}
