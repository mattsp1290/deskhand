import AppKit
import Foundation
import SpikeKit

enum Agent {
  static var logURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/homes.birb.deskhand/spike-agent.jsonl")
  }

  private static var handle: FileHandle?
  private static let measurement = MeasurementSession(
    file: URL(fileURLWithPath: ControlServer.defaultPath).deletingLastPathComponent()
      .appendingPathComponent("session-claim.json"),
    artifactID: SessionIdentity.artifact(RunContext.json))
  private static var listener: TCPListener?
  private static var listenerState: JSON = .null
  private static var accepted: [JSON] = []
  private static let started = Clock.iso()
  private static var samples = 0
  private static var peerAttempt: JSON = .null
  private static var listenerPort = 47_821

  static func log(_ kind: String, _ body: JSON) {
    let line = JSON.obj([("kind", .string(kind)), ("t", Clock.stamp()), ("body", body)])
    write(line.compact() + "\n")
  }

  private static func write(_ text: String) {
    let manager = FileManager.default
    do {
      if handle == nil {
        try manager.createDirectory(
          at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: logURL.path) {
          guard manager.createFile(atPath: logURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
          }
        }
        handle = try FileHandle(forWritingTo: logURL)
        _ = try handle?.seekToEnd()
      }
      if let size = try handle?.offset(), size > 50_000_000 {
        try handle?.close()
        handle = nil
        let rotated = logURL.appendingPathExtension("1")
        if manager.fileExists(atPath: rotated.path) { try manager.removeItem(at: rotated) }
        try manager.moveItem(at: logURL, to: rotated)
        write(text)
        return
      }
      try handle?.write(contentsOf: Data(text.utf8))
    } catch {
      FileHandle.standardError.write(Data(("agent evidence write failed: \(error)\n").utf8))
      exit(1)
    }
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
    listenerPort = port
    Dispatcher.peerCommand = peerCommand
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
      guard words.count >= 3, words[0] == "request", UUID(uuidString: words[1]) != nil else {
        return
      }
      let requestID = words[1]
      var count = 0
      var success = true
      func reply(_ value: JSON) {
        count += 1
        if value["error"] != nil || value["status"]?.stringValue == "error" { success = false }
        emit(CommandProtocol.result(value, id: requestID).compact())
      }
      defer {
        emit(CommandProtocol.completion(id: requestID, count: count, success: success).compact())
      }
      var command = Array(words.dropFirst(2))
      var token: String?
      if command.first == "session", command.count >= 3 {
        if ["begin", "resume", "end"].contains(command[1]) {
          let accepted: Bool
          switch command[1] {
          case "begin": accepted = measurement.begin(command[2])
          case "resume": accepted = measurement.resume(command[2])
          default: accepted = measurement.end(command[2])
          }
          if accepted {
            listener?.stop()
            listener = nil
            peerAttempt = .null
          }
          reply(
            .obj(
              accepted
                ? [("session", .bool(true))]
                : [
                  (
                    "error",
                    .string(measurement.error ?? "measurement session busy or invalid owner")
                  )
                ]))
          return
        }
        token = command[1]
        command.removeFirst(2)
      }
      if command == ["ping"] {
        await Dispatcher.run(command, emit: reply)
        return
      }
      guard measurement.enter(token) else {
        reply(
          .obj([
            (
              "error",
              .string(measurement.error ?? "measurement session busy, suspended or invalid owner")
            )
          ]))
        return
      }
      defer { measurement.leave() }
      await Dispatcher.run(command, emit: reply)
    }
    log(
      "control_socket",
      .obj([("path", .string(ControlServer.defaultPath)), ("error", .str(controlError))]))

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
        if measurement.isIdle, measurement.enter(nil) {
          log("capture_check", await CaptureCheck.quick())
          measurement.leave()
        }
        await Clock.sleep(ms: captureInterval * 1000)
      }
    }
    while true {
      if measurement.isIdle {
        samples += 1
        log("sample", Signals.sample())
      }
      await Clock.sleep(ms: interval * 1000)
    }
  }

  private static func peerCommand(_ words: [String]) -> JSON {
    guard words.count == 2, UUID(uuidString: words[1]) != nil else {
      return .obj([("error", .string("expected arm|collect and nonce"))])
    }
    let nonce = words[1]
    if words[0] == "collect", peerAttempt["nonce"]?.stringValue == nonce {
      return peerAttempt.setting(
        "accepted", .array(accepted.filter { $0["nonce"]?.stringValue == nonce })
      )
      .setting("context", RunContext.json)
    }
    guard words[0] == "arm", let address = Net.lanAddress()?.address else {
      return .obj([("error", .string("cannot arm peer listener"))])
    }
    listener?.stop()
    listener = nil
    accepted = []
    let candidate = TCPListener(host: address, port: listenerPort)
    let greeting = JSON.obj([("nonce", .string(nonce)), ("target_host", .string(Host.macName))])
      .compact()
    let error = candidate.start(
      greeting: { greeting },
      onAccept: { peer in
        let entry = JSON.obj([
          ("peer", .string(peer)), ("nonce", .string(nonce)), ("t", Clock.stamp()),
        ])
        Task { @MainActor in
          Agent.accepted.append(entry)
          Agent.log("peer_accept", entry)
        }
      })
    if let error { return .obj([("error", .string(error))]) }
    listener = candidate
    peerAttempt = .obj([
      ("nonce", .string(nonce)), ("address", .string(address)),
      ("port", .int(listenerPort)), ("target_host", .string(Host.macName)),
    ])
    return peerAttempt
  }

  private static func keepListening(port: Int) async {
    var bound: String?
    while true {
      guard measurement.isIdle else {
        await Clock.sleep(ms: 5000)
        continue
      }
      let address = Net.lanAddress()?.address
      if address != bound || listener == nil {
        listener?.stop()
        listener = nil
        bound = nil
        if let address {
          let candidate = TCPListener(host: address, port: port)
          let error = candidate.start(
            greeting: { "deskhand-spike agent \(Host.macName)" },
            onAccept: { peer in
              Task { @MainActor in
                let entry = JSON.obj([("peer", .string(peer)), ("t", Clock.stamp())])
                Agent.accepted.append(entry)
                Agent.log("accept", entry)
              }
            })
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
