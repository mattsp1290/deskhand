import Foundation
import Testing

@testable import SpikeKit

@Test func inheritedPipeTimeoutIsVisible() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let release = directory.appendingPathComponent("release")
  let finished = directory.appendingPathComponent("finished")
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = """
    (
      i=0
      while [ ! -f "$1/release" ] && [ "$i" -lt 100 ]; do
        /bin/sleep 0.05
        i=$((i + 1))
      done
      /usr/bin/touch "$1/finished"
    ) &
    """
  let result = Shell.run("/bin/sh", ["-c", script, "pipe-test", directory.path])
  try Data().write(to: release)
  for _ in 0..<100 where !FileManager.default.fileExists(atPath: finished.path) {
    Thread.sleep(forTimeInterval: 0.01)
  }
  #expect(FileManager.default.fileExists(atPath: finished.path))
  #expect(result.status == 0)
  #expect(result.timedOut)
  #expect(result.stderr.contains("output capture incomplete"))
}

@Test func shellCapturesBothStreams() {
  let result = Shell.run("/bin/sh", ["-c", "printf stdout; printf stderr >&2"])
  #expect(result.status == 0)
  #expect(result.stdout == "stdout")
  #expect(result.stderr == "stderr")
  #expect(!result.timedOut)
}
