import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit
import SpikeKit

/// Items 1 and 7 plus the blank/wallpaper-only spike additions: ScreenCaptureKit window list,
/// one capture per display, a wallpaper-only comparison, and capture exclusion of the harness's
/// own window and of any running sensitive app.
enum CaptureProbe {
  static let spec = ProbeSpec(
    name: "capture", items: ["1", "7", "add-wallpaper-only", "add-blank-frame"],
    summary: "SCK window list, per-display capture, wallpaper-only and blank detection, exclusion",
    run: run)

  /// Password managers, messaging and mail apps (from deskhand v0's default deny list).
  static let sensitiveBundleIDs = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "org.keepassxc.keepassxc", "com.apple.Passwords", "com.apple.keychainaccess",
    "com.apple.MobileSMS", "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
    "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop",
    "com.microsoft.teams2", "us.zoom.xos", "com.apple.mail", "com.microsoft.Outlook",
    "com.bluebubbles.messaging",
  ]

  static let magenta = (255, 0, 255)

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("capture", items: spec.items)
    let preflight = CGPreflightScreenCaptureAccess()
    report.set("preflight_screen_recording", .bool(preflight))
    report.set("lock_candidates", Signals.lockCandidates())

    // The marker is the harness's own window, used to check exclusion and the pixel mapping.
    let main = CGDisplayBounds(CGMainDisplayID())
    let markerRect = CGRect(x: main.midX - 100, y: main.midY - 100, width: 200, height: 200)
    let marker = HarnessWindow(
      global: markerRect, color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1),
      level: .popUpMenu)
    marker.show()
    defer { marker.close() }
    await settle(ms: 500)

    let content: SCShareableContent
    do {
      content = try await CaptureTools.shareableContent()
    } catch {
      report.set("shareable_content_error", CaptureTools.errorJSON(error))
      if preflight {
        report.fail("SCShareableContent failed although the preflight says granted")
        report.finding("SCShareableContent failed with the preflight granted: \(error)")
      } else {
        report.block(on: .screenRecording, "SCShareableContent: \(error.localizedDescription)")
      }
      return report
    }
    let me = content.applications.first { $0.processID == getpid() }
    let normalOnScreen = content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen }
    report.set(
      "shareable",
      .obj([
        ("displays", .int(content.displays.count)), ("windows", .int(content.windows.count)),
        ("normal_windows_on_screen", .int(normalOnScreen.count)),
        ("applications", .int(content.applications.count)),
        ("harness_app_listed", .bool(me != nil)),
        (
          "owners_with_normal_windows",
          .strings(
            Array(Set(normalOnScreen.compactMap { $0.owningApplication?.bundleIdentifier }))
              .sorted())
        ),
      ]))
    report.finding(
      "SCShareableContent: \(content.displays.count) display(s), \(content.windows.count) windows "
        + "(\(normalOnScreen.count) normal on screen)")

    var displayResults: [JSON] = []
    var sensitiveResults: [JSON] = []
    let wanted = Set(sensitiveBundleIDs + options.excludeBundleIDs)
    for display in content.displays {
      var entry: [(String, JSON)] = [
        ("display_id", .int(Int(display.displayID))), ("frame", Geometry.json(display.frame)),
      ]
      let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
      entry.append(("filter", CaptureTools.filterInfo(filter)))
      let full: CGImage
      do {
        full = try await CaptureTools.capture(filter)
      } catch {
        entry.append(("capture_error", CaptureTools.errorJSON(error)))
        displayResults.append(.obj(entry))
        report.finding("display \(display.displayID): capture failed: \(error.localizedDescription)")
        continue
      }
      let stats = CaptureTools.stats(full)
      entry.append(("stats", stats))
      let scale = Double(full.width) / Double(display.frame.width)
      func pixels(_ rect: CGRect) -> CGRect {
        CGRect(
          x: (rect.minX - display.frame.minX) * scale, y: (rect.minY - display.frame.minY) * scale,
          width: rect.width * scale, height: rect.height * scale)
      }

      // Wallpaper-only: compare with a capture of the desktop-level windows alone.
      let desktopWindows = content.windows.filter {
        $0.windowLayer < 0 && $0.frame.intersects(display.frame)
      }
      let others = normalOnScreen.filter {
        $0.frame.intersects(display.frame) && $0.owningApplication?.processID != getpid()
          && $0.frame.width * $0.frame.height > 0.01 * display.frame.width * display.frame.height
      }
      entry.append(("desktop_level_windows", .int(desktopWindows.count)))
      entry.append(("other_normal_windows", .int(others.count)))
      var wallpaperOnly: Bool?
      if !desktopWindows.isEmpty {
        let wallpaperFilter = SCContentFilter(display: display, including: desktopWindows)
        if let wallpaper = try? await CaptureTools.capture(wallpaperFilter) {
          let diff = CaptureTools.difference(full, wallpaper)
          entry.append(("vs_wallpaper_only", diff))
          let changed = diff["changed_cell_fraction"]?.doubleValue ?? 1
          wallpaperOnly = !others.isEmpty && changed < 0.01
        }
      }
      let blank =
        (stats["coarse_colors"]?.intValue ?? 99) <= 2
        || (stats["luminance_stddev"]?.doubleValue ?? 99) < 1
      entry.append(("wallpaper_only_suspected", .bool(wallpaperOnly)))
      entry.append(("blank_suspected", .bool(blank)))
      report.finding(
        "display \(display.displayID): captured \(full.width)x\(full.height) px, "
          + "wallpaper-only suspected: \(wallpaperOnly.map { $0 ? "YES" : "no" } ?? "n/a"), "
          + "blank suspected: \(blank ? "YES" : "no")")

      // The harness's own window: visible in a plain capture, gone when its app is excluded.
      if display.frame.contains(markerRect), let me {
        let inner = pixels(markerRect.insetBy(dx: 30, dy: 30))
        let shown = CaptureTools.colorFraction(full, in: inner, color: magenta)
        let excludedFilter = SCContentFilter(
          display: display, excludingApplications: [me], exceptingWindows: [])
        var hidden: Double?
        if let excluded = try? await CaptureTools.capture(excludedFilter) {
          hidden = CaptureTools.colorFraction(excluded, in: inner, color: magenta)
          if let directory = options.imageDirectory {
            CaptureTools.savePNG(
              excluded, to: directory.appendingPathComponent("display-\(display.displayID)-excluded-self.png"))
          }
        }
        entry.append(
          (
            "own_window_exclusion",
            .obj([
              ("marker_fraction_plain", .num(shown)), ("marker_fraction_excluded", .num(hidden)),
            ])
          ))
        let works = (shown ?? 0) > 0.8 && (hidden ?? 1) < 0.05
        report.finding(
          "own window: \(Int((shown ?? 0) * 100))% visible in plain capture, "
            + "\(Int((hidden ?? 1) * 100))% visible with the harness excluded (exclusion "
            + "\(works ? "works" : "DID NOT behave as expected"))")
      }

      // Sensitive apps that are running with windows on this display.
      for app in content.applications where wanted.contains(app.bundleIdentifier) {
        let windows = normalOnScreen.filter {
          $0.owningApplication?.processID == app.processID && $0.frame.intersects(display.frame)
        }
        guard !windows.isEmpty else { continue }
        let excludedFilter = SCContentFilter(
          display: display, excludingApplications: [app], exceptingWindows: [])
        guard let excluded = try? await CaptureTools.capture(excludedFilter) else { continue }
        var perWindow: [JSON] = []
        for window in windows {
          let rect = pixels(window.frame.intersection(display.frame))
          guard let a = full.cropping(to: rect.integral), let b = excluded.cropping(to: rect.integral)
          else { continue }
          let topmost = WindowList.stack(at: CGPoint(x: window.frame.midX, y: window.frame.midY))
            .first?.ownerPID == app.processID
          perWindow.append(
            .obj([
              ("window_id", .int(Int(window.windowID))),
              ("frame", Geometry.json(window.frame)),
              ("topmost_at_center", .bool(topmost)),
              ("plain_vs_excluded", CaptureTools.difference(a, b)),
            ]))
        }
        if let directory = options.imageDirectory {
          CaptureTools.savePNG(
            excluded,
            to: directory.appendingPathComponent(
              "display-\(display.displayID)-excluded-\(app.bundleIdentifier).png"))
        }
        sensitiveResults.append(
          .obj([
            ("bundle_id", .string(app.bundleIdentifier)), ("display_id", .int(Int(display.displayID))),
            ("windows", .array(perWindow)),
          ]))
      }
      displayResults.append(.obj(entry))
    }
    report.set("displays", .array(displayResults))
    report.set("sensitive_app_exclusion", .array(sensitiveResults))
    if sensitiveResults.isEmpty {
      report.note("no sensitive app had windows on screen: run trial exclusion for item 7")
    } else {
      for result in sensitiveResults {
        let windows = result["windows"]?.arrayValue ?? []
        let changed = windows.compactMap {
          $0["plain_vs_excluded"]?["changed_cell_fraction"]?.doubleValue
        }
        report.finding(
          "\(result["bundle_id"]?.stringValue ?? "?"): excluded capture changed "
            + "\(changed.map { "\(Int($0 * 100))%" }.joined(separator: ", ")) of its window area")
      }
    }
    if RunContext.launchedBy != .launchAgent {
      report.note("not run as the LaunchAgent: wallpaper-only behaviour must be read from the agent run")
    }
    return report
  }
}
