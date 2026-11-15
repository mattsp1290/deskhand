import Foundation

public struct CaptureManifest {
  public let captureID: String
  public var requested: [JSON] = []
  public var savedImages: [JSON] = []
  public var failures: [String] = []

  public init(captureID: String = UUID().uuidString) { self.captureID = captureID }

  public var json: JSON {
    .obj([
      ("capture_id", .string(captureID)), ("requested", .array(requested)),
      ("saved_images", .array(savedImages)), ("failures", .strings(failures)),
    ])
  }

  public static func previews(_ manifest: JSON, selected: [String], root: URL) throws -> [String] {
    guard !selected.isEmpty, let id = manifest["capture_id"]?.stringValue,
      UUID(uuidString: id) != nil,
      let requested = manifest["requested"]?.arrayValue, !requested.isEmpty,
      manifest["failures"]?.arrayValue == [],
      let saved = manifest["saved_images"]?.arrayValue, saved.count == requested.count,
      Set(requested.compactMap { $0["bundle_id"]?.stringValue }) == Set(selected)
    else {
      throw TrialAbort.failed("current capture manifest is incomplete")
    }
    let directory = root.appendingPathComponent(id).standardizedFileURL.resolvingSymlinksInPath()
    var paths: [String] = []
    for request in requested {
      let matching = saved.filter {
        $0["bundle_id"] == request["bundle_id"] && $0["display_id"] == request["display_id"]
      }
      guard matching.count == 1, let path = matching.first?["path"]?.stringValue else {
        throw TrialAbort.failed("missing requested app/display capture")
      }
      let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
      guard url.deletingLastPathComponent() == directory, url.pathExtension == "png",
        FileManager.default.fileExists(atPath: url.path)
      else { throw TrialAbort.failed("capture path is outside the current manifest") }
      paths.append(url.path)
    }
    guard Set(paths).count == paths.count else {
      throw TrialAbort.failed("duplicate capture paths")
    }
    return paths
  }
}
