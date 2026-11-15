import AppKit
import Foundation
import SpikeKit

enum HarnessTrials {
  static var all: [TrialSpec] {
    [
      PermissionsTrial.spec, LockTrial.spec, wake, exclusion, coordinates,
    ]
  }

  static var wake: TrialSpec {
    TrialSpec(
      name: "wake", items: ["5"], effort: 3,
      summary:
        "display sleep, then IOPMAssertionDeclareUserActivity: does the display wake, is it locked",
      humanActions: "unlock with Touch ID after each cycle",
      run: { env in
        env.step(
          "The harness puts the display to sleep, waits, then declares user activity. You only "
            + "unlock afterwards (Touch ID). \(env.count) cycles.")
        await env.waitEnter("Ready")
        var woke = 0
        var lockedAfter = 0
        for attempt in 1...env.count {
          let pre = await env.sample()
          let sleep = await env.act("display-sleep")
          let asleep = await env.poll(everyMs: 250, timeoutMs: 10_000) { sample in
            sample["displays"]?.arrayValue?.contains {
              $0["main"]?.boolValue == true && $0["asleep"]?.boolValue == true
            } ?? false
          }
          await Clock.sleep(ms: 4000)
          let beforeWake = await env.sample()
          let declare = await env.act("declare-activity", "3000")
          let afterWake = await env.sample()
          let displayOn =
            declare["displays_after"]?.arrayValue?.contains {
              $0["main"]?.boolValue == true && $0["asleep"]?.boolValue == false
            } ?? false
          let locked = LockTrial.looksLocked(afterWake)
          if displayOn { woke += 1 }
          if locked { lockedAfter += 1 }
          env.say(
            "[\(attempt)/\(env.count)] display woke: \(displayOn), locked: \(locked). Unlock if needed."
          )
          _ = await env.poll(everyMs: 500, timeoutMs: 600_000) { LockTrial.looksUnlocked($0) }
          env.record(
            .obj([
              ("attempt", .int(attempt)), ("pre", pre), ("sleep", sleep),
              ("went_to_sleep", .bool(asleep.last.map { _ in true } ?? false)),
              ("before_wake", beforeWake), ("declare", declare), ("after_wake", afterWake),
              ("display_woke", .bool(displayOn)), ("locked_after_wake", .bool(locked)),
            ]))
          await Clock.sleep(ms: 2000)
        }
        env.report.finding(
          "IOPMAssertionDeclareUserActivity woke the display in \(woke)/\(env.count); the screen "
            + "was locked after waking in \(lockedAfter)/\(env.count)")
        env.finish()
      })
  }

  static var exclusion: TrialSpec {
    TrialSpec(
      name: "exclusion", items: ["7"], effort: 4,
      summary: "capture exclusion of your real password manager and messaging apps",
      humanActions: "open those apps, pick them from a list, look at the excluded captures",
      run: { env in
        let installed = CaptureProbe.sensitiveBundleIDs.filter {
          NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        env.step(
          "Open your password manager and your messaging apps so each has a window on screen, "
            + "not covered by others. A locked vault window is fine; nothing secret has to be shown. "
            + "Installed ones the harness knows: \(installed.joined(separator: ", ")).")
        await env.waitEnter("Done")
        let apps = NSWorkspace.shared.runningApplications.filter {
          $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
        for (index, app) in apps.enumerated() {
          env.say(
            "  \(index + 1). \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "no bundle id"))"
          )
        }
        let picked = await env.ask(
          "picked_apps", "Numbers of your password manager and messaging apps (comma-separated)",
          choices: [])
        let chosen = picked.split(separator: ",").compactMap {
          Int($0.trimmingCharacters(in: .whitespaces))
        }
        .filter { $0 >= 1 && $0 <= apps.count }.map { apps[$0 - 1] }
        let ids = chosen.compactMap(\.bundleIdentifier)
        var words = ["probe", "capture", "--save-images"]
        for id in ids { words += ["--exclude-bundle-id", id] }
        let result = await env.call(words).last.orNull
        var clickable: [JSON] = []
        let windows = WindowList.onScreen()
        for app in chosen {
          for window in windows where window.ownerPID == app.processIdentifier && window.layer == 0
          {
            guard let bounds = window.bounds else { continue }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let top = WindowList.stack(at: center, in: windows).first
            clickable.append(
              .obj([
                ("bundle_id", .str(app.bundleIdentifier)), ("window", .int(window.number)),
                ("topmost_owner_is_app", .bool(top?.ownerPID == app.processIdentifier)),
                ("event_target_window", .int(WindowList.eventTargetWindowNumber(at: center))),
              ]))
          }
        }
        env.record(.obj([("capture", result), ("clickable", .array(clickable))]))
        let directory = CaptureTools.imageCacheDirectory
        let images =
          ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
          .filter { $0.contains("excluded") }.map { directory.appendingPathComponent($0).path }
        if !images.isEmpty { _ = await Shell.runAsync("/usr/bin/open", images) }
        let hidden = await env.ask(
          "excluded_apps_hidden",
          "In the images that opened (\(images.count)), are the chosen apps' windows hidden?",
          choices: ["y", "n", "partly"])
        let reachable = clickable.filter {
          $0["event_target_window"]?.intValue == $0["window"]?.intValue
        }.count
        env.report.finding(
          "excluded apps \(ids) hidden in captures (person): \(hidden); events at their window "
            + "centres would reach them: \(reachable)/\(clickable.count) windows")
        if await env.ask("delete_images", "Delete the captured images now?") == "y" {
          for image in images { try? FileManager.default.removeItem(atPath: image) }
        }
        env.finish()
      })
  }

  static var coordinates: TrialSpec {
    TrialSpec(
      name: "coordinates", items: ["8"], effort: 6,
      summary:
        "coordinate mapping per display arrangement (Retina, non-Retina, left of main, scaled)",
      humanActions: "rearrange displays 2-3 times in System Settings > Displays",
      run: { env in
        let arrangements = [
          ("as_is", "Leave the displays as they are."),
          (
            "external_left",
            "Attach a non-Retina external display if you have one and place it LEFT of the main "
              + "display (System Settings > Displays > Arrange…)."
          ),
          (
            "scaled",
            "Set the built-in display to a scaled resolution (Displays > More Space or Larger Text)."
          ),
        ]
        for (name, instruction) in arrangements {
          env.step(instruction)
          if name != "as_is" {
            _ = await env.act(
              "open-settings", "x-apple.systempreferences:com.apple.Displays-Settings.extension")
          }
          let answer = await env.ask(
            "arrangement_\(name)", "Ready? (s skips this arrangement)", choices: ["y", "s"])
          if answer == "s" { continue }
          let geometry = await env.call(["probe", "environment"]).last.orNull
          let mapping = await env.call(["probe", "coordinates"]).last.orNull
          let pointer = await env.call(["probe", "input-post"]).last.orNull
          env.record(
            .obj([
              ("arrangement", .string(name)), ("environment", geometry), ("coordinates", mapping),
              ("input_post", pointer),
            ]))
          for finding in mapping["findings"]?.arrayValue ?? [] {
            env.report.finding("\(name): \(finding.stringValue ?? "")")
          }
          for finding in pointer["findings"]?.arrayValue ?? []
          where finding.stringValue?.contains("pointer") == true {
            env.report.finding("\(name): \(finding.stringValue ?? "")")
          }
        }
        env.say("Restore your display arrangement when you like.")
        env.finish()
      })
  }
}
