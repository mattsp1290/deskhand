import Foundation
import SpikeKit

/// The one up-front permission session (items 1, 2, 9 and the spike additions). It grants one
/// permission at a time and, after each, checks from the running LaunchAgent whether the grant
/// is visible and works without a restart.
enum PermissionsTrial {
  static var spec: TrialSpec {
    TrialSpec(
      name: "permissions", items: ["1", "2", "9", "add-event-synthesizing", "add-remote-desktop"],
      effort: 1,
      summary: "grant Screen Recording, then Accessibility, then (only if needed) Input Monitoring",
      humanActions:
        "toggle deskhand-spike on in 2-3 System Settings lists, answer 4-6 y/n questions",
      run: run)
  }

  static let panes = [
    "screen": "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
    "accessibility":
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    "listen": "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
    "local_network": "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
  ]

  static func run(_ env: TrialEnv) async {
    if env.executor.label != "launch_agent" {
      env.say(
        "WARNING: the LaunchAgent is not reachable; grants would be measured for this terminal. "
          + "Install with scripts/install.sh first.")
    }
    let baseline = await env.sample()
    env.record(.obj([("step", .string("baseline")), ("sample", baseline)]))
    func granted(_ sample: JSON, _ key: String) -> Bool {
      sample["permissions"]?[key]?.boolValue == true
    }

    // 1. Screen Recording.
    if granted(baseline, "screen_recording") {
      env.say("Screen Recording is already granted.")
    } else {
      env.step("Screen Recording")
      let request = await env.act("request", "screen")
      _ = await env.act("open-settings", panes["screen"]!)
      env.say(
        "In System Settings > Privacy & Security > Screen & System Audio Recording, turn ON "
          + "deskhand-spike. If macOS offers 'Quit & Reopen', choose 'Later' (the harness checks "
          + "whether a restart is needed).")
      let started = Clock.monoMs()
      let samples = await env.poll(everyMs: 1000, timeoutMs: 600_000) {
        granted($0, "screen_recording")
      }
      let visible = samples.last.map { granted($0, "screen_recording") } ?? false
      let capture = await env.act("capture-check")
      env.record(
        .obj([
          ("step", .string("screen_recording")), ("request", request),
          ("visible_to_running_agent", .bool(visible)),
          ("seconds_until_visible", .double(((Clock.monoMs() - started) / 1000).rounded())),
          ("capture_without_restart", capture),
        ]))
      let works = capture["capture"]?["stats"] != nil
      env.report.finding(
        "Screen Recording grant visible to the running agent without restart: \(visible ? "yes" : "NO"); "
          + "capture worked without restart: \(works ? "yes" : "NO")")
    }
    let quitReopen = await env.ask(
      "quit_and_reopen_prompt", "Did macOS ask to 'Quit & Reopen' deskhand-spike?")
    let remoteDesktop = await env.ask(
      "remote_desktop_list",
      "In Screen & System Audio Recording, is there a separate 'Remote Desktop' section or list?",
      choices: ["y", "n", "unsure"])
    env.report.finding(
      "Quit & Reopen prompt: \(quitReopen); separate Remote Desktop list in Settings: \(remoteDesktop)"
    )

    // 2. Accessibility alone, then posting.
    let afterScreen = await env.sample()
    if !granted(afterScreen, "accessibility") {
      env.step("Accessibility (only this one for now)")
      let request = await env.act("request", "accessibility")
      _ = await env.act("open-settings", panes["accessibility"]!)
      env.say(
        "Turn ON deskhand-spike under Privacy & Security > Accessibility. Do not change Input "
          + "Monitoring yet.")
      let samples = await env.poll(everyMs: 1000, timeoutMs: 600_000) {
        granted($0, "accessibility")
      }
      env.record(
        .obj([
          ("step", .string("accessibility")), ("request", request),
          ("sample", samples.last.orNull),
        ]))
    }
    var posting = await postingCheck(env, label: "accessibility_only")
    if !posting {
      env.step("Posting did not work with Accessibility alone. Trying the post-event request.")
      let request = await env.act("request", "post")
      env.record(.obj([("step", .string("request_post_event")), ("request", request)]))
      _ = await env.ask(
        "post_event_prompt", "Did a new prompt or a new System Settings list appear?",
        choices: ["y", "n"])
      posting = await postingCheck(env, label: "after_post_event_request")
    }
    if !posting {
      env.step("Input Monitoring")
      _ = await env.act("request", "listen")
      _ = await env.act("open-settings", panes["listen"]!)
      env.say("Turn ON deskhand-spike under Privacy & Security > Input Monitoring.")
      _ = await env.poll(everyMs: 1000, timeoutMs: 600_000) { granted($0, "listen_event") }
      posting = await postingCheck(env, label: "with_input_monitoring")
    }
    if !posting {
      env.step("Restarting the LaunchAgent to see whether the grants need a restart.")
      let uid = getuid()
      let kick = await Shell.runAsync(
        "/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(RunContext.agentLabel)"], timeout: 15)
      env.record(.obj([("step", .string("agent_restart")), ("launchctl", kick.json)]))
      await Clock.sleep(ms: 3000)
      posting = await postingCheck(env, label: "after_agent_restart")
    }
    let lists = await env.ask(
      "lists_showing_deskhand",
      "Which Privacy & Security lists show deskhand-spike now? (type them, e.g. 'screen, accessibility')",
      choices: [])
    env.report.finding("lists showing deskhand-spike (person): \(lists)")

    // 3. Local network (item 9).
    env.step("Local network")
    let listener = await env.call(["probe", "listener"]).last.orNull
    env.record(.obj([("step", .string("listener_probe")), ("result", listener)]))
    let prompt = await env.ask(
      "local_network_prompt",
      "Has a prompt about 'finding devices on your local network' appeared for deskhand-spike "
        + "at any point since install?", choices: ["y", "n"])
    _ = await env.act("open-settings", panes["local_network"]!)
    let listed = await env.ask(
      "local_network_listed",
      "Is deskhand-spike listed under Privacy & Security > Local Network?",
      choices: ["y", "n", "unsure"])
    env.report.finding(
      "Local Network prompt seen: \(prompt); listed under Local Network: \(listed)")
    env.report.finding("posting works at the end of the session: \(posting ? "yes" : "NO")")
    env.finish()
  }

  /// Whether posting works from the agent right now: a 1 px pointer nudge, then the harness's
  /// input-post probe when it is available.
  static func postingCheck(_ env: TrialEnv, label: String) async -> Bool {
    let nudge = await env.act("nudge-pointer")
    let probe = await env.call(["probe", "input-post"]).last.orNull
    let moved = nudge["moved"]?.boolValue == true
    let delivered = probe["evidence"]?["delivered_any"]?.boolValue
    let works = delivered ?? moved
    env.record(
      .obj([
        ("step", .string("posting_check")), ("label", .string(label)), ("nudge", nudge),
        ("input_post", probe), ("works", .bool(works)),
      ]))
    env.report.finding(
      "posting (\(label)): pointer nudge moved \(moved), input-post delivered "
        + "\(delivered.map { "\($0)" } ?? "n/a"), preflights \(nudge["sample"]?["permissions"]?.compact() ?? "?")"
    )
    return works
  }
}
