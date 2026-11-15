import Darwin
import Foundation
import Synchronization

/// Wall-clock and monotonic timestamps. The monotonic clock keeps counting while the Mac sleeps,
/// so lock and wake timelines from the agent and from the trial driver line up.
public nonisolated enum Clock {
  /// Milliseconds on `CLOCK_MONOTONIC` (shared by every process on the Mac).
  public static func monoMs() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000
  }

  public static func iso(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  /// A timestamp pair for evidence.
  public static func stamp() -> JSON {
    .obj([("at", .string(iso())), ("mono_ms", .double(monoMs().rounded()))])
  }

  public static func sleep(ms: Int) async {
    try? await Task.sleep(for: .milliseconds(ms))
  }
}

/// Facts about this Mac that every result carries.
public nonisolated enum Host {
  /// The name used for `docs/spike-results/<mac>/`: `DESKHAND_SPIKE_MAC`, else the lowercased
  /// local host name.
  public static let macName: String = computeMacName()

  private static func computeMacName() -> String {
    if let name = ProcessInfo.processInfo.environment["DESKHAND_SPIKE_MAC"], !name.isEmpty {
      return name
    }
    if let name = localHostName() { return name.lowercased() }
    return ProcessInfo.processInfo.hostName.lowercased()
  }

  public static let macOSVersion: String = computeMacOSVersion()

  private static func computeMacOSVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let build = sysctlString("kern.osversion") ?? "?"
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(build))"
  }

  public static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  public static func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
  }

  private static func localHostName() -> String? {
    let result = Shell.run("/usr/sbin/scutil", ["--get", "LocalHostName"], timeout: 3)
    let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.status == 0 && !name.isEmpty ? name : nil
  }
}

/// Runs a helper tool and captures its output. Never used with secrets.
public nonisolated enum Shell {
  public struct Result: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var json: JSON {
      .obj([
        ("status", .int(Int(status))), ("stdout", .string(stdout)), ("stderr", .string(stderr)),
        ("timed_out", .bool(timedOut)),
      ])
    }
  }

  public static func run(_ path: String, _ arguments: [String], timeout: Double = 10) -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return Result(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
    }
    // Drain both pipes while the tool runs, so a chatty tool never blocks on a full pipe.
    let outBox = PipeCapture()
    let errBox = PipeCapture()
    let group = DispatchGroup()
    for (pipe, box) in [(out, outBox), (err, errBox)] {
      let handle = pipe.fileHandleForReading
      DispatchQueue.global().async(group: group) {
        let data = handle.readDataToEndOfFile()
        box.data.withLock { $0 = data }
      }
    }
    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false
    while process.isRunning {
      if Date() > deadline {
        process.terminate()
        timedOut = true
        break
      }
      usleep(10_000)
    }
    process.waitUntilExit()
    let captureComplete = group.wait(timeout: .now() + 2) == .success
    let stdout = outBox.data.withLock { String(decoding: $0, as: UTF8.self) }
    var stderr = errBox.data.withLock { String(decoding: $0, as: UTF8.self) }
    if !captureComplete {
      if !stderr.isEmpty { stderr += "\n" }
      stderr += "output capture incomplete: pipes did not reach EOF within 2 seconds"
    }
    return Result(
      status: process.terminationStatus, stdout: stdout, stderr: stderr,
      timedOut: timedOut || !captureComplete)
  }

  private final class PipeCapture: Sendable {
    let data = Mutex(Data())
  }

  /// Runs off the main actor so the run loop keeps serving windows and notifications.
  public static func runAsync(_ path: String, _ arguments: [String], timeout: Double = 10) async
    -> Result
  {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: run(path, arguments, timeout: timeout))
      }
    }
  }
}
