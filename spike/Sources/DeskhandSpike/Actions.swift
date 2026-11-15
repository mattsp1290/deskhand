import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
@preconcurrency import ScreenCaptureKit
import SpikeKit

enum Actions {
  private static var authPrompt: Process?

  static func run(_ words: [String]) async -> JSON {
    let name = words.first ?? ""
    let argument = words.dropFirst().first
    var result: [(String, JSON)] = [("action", .string(name)), ("before", Clock.stamp())]
    switch name {
    case "lock-shortcut":
      result.append(("preflight_post_event", .bool(CGPreflightPostEventAccess())))
      let posted = await Post.chord(kVK_ANSI_Q, modifiers: [kVK_Control, kVK_Command])
      result.append(("posted", .bool(posted)))
    case "display-sleep":
      let run = await Shell.runAsync("/usr/bin/pmset", ["displaysleepnow"], timeout: 5)
      result.append(("pmset", run.json))
    case "hot-corner":
      let main = CGDisplayBounds(CGMainDisplayID())
      let corners: [String: CGPoint] = [
        "tl": CGPoint(x: main.minX, y: main.minY), "tr": CGPoint(x: main.maxX - 1, y: main.minY),
        "bl": CGPoint(x: main.minX, y: main.maxY - 1),
        "br": CGPoint(x: main.maxX - 1, y: main.maxY - 1),
      ]
      guard let corner = corners[argument ?? ""] else {
        result.append(("error", .string("corner must be tl, tr, bl or br")))
        break
      }
      result.append(("preflight_post_event", .bool(CGPreflightPostEventAccess())))
      let start = Post.location()
      await Post.glide(to: CGPoint(x: main.midX, y: main.midY), steps: 5)
      await Post.glide(to: corner, steps: 25)
      await Clock.sleep(ms: 1200)
      result.append(("reached", Geometry.json(Post.location())))
      result.append(("started_at", Geometry.json(start)))
      await Post.glide(to: CGPoint(x: main.midX, y: main.midY), steps: 10)
    case "declare-activity":
      let before = Signals.displaysAsleep()
      let idleBefore = Signals.idle()
      var assertion: IOPMAssertionID = 0
      let status = IOPMAssertionDeclareUserActivity(
        "deskhand-spike wake trial" as CFString, kIOPMUserActiveLocal, &assertion)
      await Clock.sleep(ms: Int(argument ?? "") ?? 3000)
      result.append(("status", .int(Int(status))))
      result.append(("displays_before", before))
      result.append(("displays_after", Signals.displaysAsleep()))
      result.append(("idle_before", idleBefore))
      result.append(("idle_after", Signals.idle()))
      if assertion != 0 { IOPMAssertionRelease(assertion) }
    case "nudge-pointer":
      let start = Post.location()
      Post.move(to: CGPoint(x: start.x + 1, y: start.y))
      await Clock.sleep(ms: 150)
      let moved = Post.location()
      Post.move(to: start)
      result.append(("start", Geometry.json(start)))
      result.append(("after_post", Geometry.json(moved)))
      result.append(("moved", .bool(moved != start)))
    case "type-harmless":
      result.append(("secure_input", Signals.secureInput()))
      result.append(("typed", .bool(await Post.type("xyz"))))
    case "escape":
      result.append(("posted", .bool(await Post.chord(kVK_Escape))))
    case "capture-check":
      result.append(("capture", await CaptureCheck.quick()))
    case "request":
      result.append(("requested", .string(argument ?? "")))
      switch argument {
      case "screen": result.append(("returned", .bool(CGRequestScreenCaptureAccess())))
      case "post": result.append(("returned", .bool(CGRequestPostEventAccess())))
      case "listen": result.append(("returned", .bool(CGRequestListenEventAccess())))
      case "accessibility":
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        result.append(("returned", .bool(AXIsProcessTrustedWithOptions(options))))
      default: result.append(("error", .string("request screen|post|listen|accessibility")))
      }
      result.append(("preflights", Signals.preflights()))
    case "auth-prompt":
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", "do shell script \"/usr/bin/true\" with administrator privileges"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        authPrompt = process
        result.append(("started", .bool(true)))
      } catch {
        result.append(("error", .string("\(error)")))
      }
    case "dismiss-auth-prompt":
      if let process = authPrompt, process.isRunning { process.terminate() }
      authPrompt = nil
      result.append(("dismissed", .bool(true)))
    case "open-settings":
      if let text = argument, text.hasPrefix("x-apple.systempreferences:"),
        let url = URL(string: text)
      {
        result.append(("opened", .bool(NSWorkspace.shared.open(url))))
      } else {
        result.append(("error", .string("needs an x-apple.systempreferences: URL")))
      }
    default:
      result.append(("error", .string("unknown action \(name)")))
    }
    result.append(("after", Clock.stamp()))
    result.append(("sample", Signals.sample()))
    return .obj(result)
  }
}

enum CaptureCheck {
  static func quick() async -> JSON {
    var result: [(String, JSON)] = [
      ("preflight_screen_recording", .bool(CGPreflightScreenCaptureAccess()))
    ]
    let content: SCShareableContent
    do {
      content = try await CaptureTools.shareableContent()
    } catch {
      result.append(("shareable_content_error", CaptureTools.errorJSON(error)))
      return .obj(result)
    }
    let normal = content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen }
    result.append(("windows", .int(content.windows.count)))
    result.append(("normal_windows_on_screen", .int(normal.count)))
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
      result.append(("error", .string("main display not in shareable content")))
      return .obj(result)
    }
    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    do {
      let image = try await CaptureTools.capture(filter)
      result.append(("stats", CaptureTools.stats(image)))
      let desktop = content.windows.filter {
        $0.windowLayer < 0 && $0.frame.intersects(display.frame)
      }
      if !desktop.isEmpty,
        let wallpaper = try? await CaptureTools.capture(
          SCContentFilter(display: display, including: desktop))
      {
        let diff = CaptureTools.difference(image, wallpaper)
        result.append(("vs_wallpaper_only", diff))
        let others = normal.filter { $0.frame.intersects(display.frame) }
        result.append(
          (
            "wallpaper_only_suspected",
            .bool(!others.isEmpty && (diff["changed_cell_fraction"]?.doubleValue ?? 1) < 0.01)
          ))
      }
    } catch {
      result.append(("capture_error", CaptureTools.errorJSON(error)))
    }
    return .obj(result)
  }
}
