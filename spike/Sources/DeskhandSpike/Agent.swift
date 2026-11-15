import AppKit
import Foundation
import SpikeKit

/// The LaunchAgent mode: an inbound TCP listener on the LAN address (item 9), periodic state
/// samples and capture checks to a log (items 1, 2, 4 over time), and the owner-only control
/// socket the driver uses to run probes and trial actions with deskhand's own TCC grants.
enum Agent {
  static var logURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/homes.birb.deskhand/spike-agent.jsonl")
  }

  private static var handle: FileHandle?
  private static var listener: TCPListener?
  private static var listenerState: JSON = .null
  private static var accepted: [JSON] = []
  private static let started = Clock.iso()
  private static var samples = 0

  static func log(_ kind: String, _ body: JSON) {
    let line = JSON.obj([("kind", .string(kind)), ("t", Clock.stamp()), ("body", body)])
    write(line.compact() + "\n")
  }

  private static func write(_ text: String) {
    let manager = FileManager.default
    if handle == nil {
      try? manager.createDirectory(
        at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !manager.fileExists(atPath: logURL.path) {
        manager.createFile(atPath: logURL.path, contents: nil)
      }
      handle = try? FileHandle(forWritingTo: logURL)
      _ = try? handle?.seekToEnd()
    }
    if let size = try? handle?.offset(), size > 50_000_000 {
      try? handle?.close()
      handle = nil
      let rotated = logURL.appendingPathExtension("1")
      try? manager.removeItem(at: rotated)
      try? manager.moveItem(at: logURL, to: rotated)
      write(text)
      return
    }
    handle?.write(Data(text.utf8))
  }

  static func run(_ arguments: [String]) async {
    var interval = 30
    var captureInterval = 900
    var port = 47_821
    var index = 0
    while index + 1 < arguments.count {
      switch arguments[index] {
      case "--interval": interval = Int(arguments[index + 1]) ?? interval
      case "--capture-interval": captureInterval = Int(arguments[index + 1]) ?? captureInterval
      case "--port": port = Int(arguments[index + 1]) ?? port
      default: break
      }
      index += 2
    }
    SignalEvents.shared.onEvent = { event in Agent.log("event", event) }
    SignalEvents.shared.start()
    log(
      "start",
      .obj([
        ("context", RunContext.json), ("permissions", Signals.preflights()),
        ("interval_s", .int(interval)), ("capture_interval_s", .int(captureInterval)),
        ("port", .int(port)),
      ]))

    let control = ControlServer()
    let controlError = control.start { words, emit in
      Agent.log("control", .strings(words))
      await Dispatcher.run(words) { emit($0.compact()) }
    }
    log("control_socket", .obj([("path", .string(ControlServer.defaultPath)), ("error", .str(controlError))]))

    Dispatcher.agentStatus = {
      .obj([
        ("agent", .bool(true)), ("started", .string(started)), ("samples", .int(samples)),
        ("log", .string(logURL.path)), ("listener", listenerState),
        ("accepted", .array(accepted.suffix(20))), ("context", RunContext.json),
        ("permissions", Signals.preflights()),
      ])
    }

    Task { await keepListening(port: port) }
    Task {
      while true {
        await Clock.sleep(ms: 2000)
        log("capture_check", await CaptureCheck.quick())
        await Clock.sleep(ms: captureInterval * 1000)
      }
    }
    while true {
      samples += 1
      log("sample", Signals.sample())
      await Clock.sleep(ms: interval * 1000)
    }
  }

  /// Binds the LAN address, retrying every 5 s (the address may not exist yet at login) and
  /// rebinding when it changes.
  private static func keepListening(port: Int) async {
    var bound: String?
    while true {
      let address = Net.lanAddress()?.address
      if address != bound {
        listener?.stop()
        listener = nil
        bound = nil
        if let address {
          let candidate = TCPListener(host: address, port: port)
          let error = candidate.start(greeting: { "deskhand-spike agent \(Host.macName)" }) { peer in
            Task { @MainActor in
              let entry = JSON.obj([("peer", .string(peer)), ("t", Clock.stamp())])
              Agent.accepted.append(entry)
              Agent.log("accept", entry)
            }
          }
          listenerState = .obj([
            ("address", .string(address)), ("port", .int(port)), ("error", .str(error)),
          ])
          log("listener", listenerState)
          if error == nil {
            listener = candidate
            bound = address
          }
        }
      }
      await Clock.sleep(ms: 5000)
    }
  }
}
