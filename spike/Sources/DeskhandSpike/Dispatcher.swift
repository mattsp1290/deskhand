import Foundation
import SpikeInput
import SpikeKit

enum Catalog {
  static var probes: [ProbeSpec] {
    [
      EnvironmentProbe.spec, PermissionsProbe.spec, IdentityProbe.spec, SessionProbe.spec,
      ActivityProbe.spec, ListenerProbe.spec, CaptureProbe.spec, CoordinatesProbe.spec,
    ] + InputCatalog.probes
  }

  static var trials: [TrialSpec] {
    (HarnessTrials.all + InputCatalog.trials).sorted { $0.effort < $1.effort }
  }

  static func expectedProbes(_ words: [String]) -> [String]? {
    var words = words
    if words.first == "session", words.count > 2, UUID(uuidString: words[1]) != nil {
      words.removeFirst(2)
    }
    guard words.first == "probe" else { return nil }
    var names: [String] = []
    var index = 1
    while index < words.count {
      if ["--exclude-bundle-id", "--listener-port"].contains(words[index]) {
        index += 2
        continue
      }
      if words[index] != "--save-images" { names.append(words[index]) }
      index += 1
    }
    if names == ["all-automatic"] { return probes.filter(\.automatic).map(\.name) }
    if names == ["list"] { return probes.map(\.name) }
    return names
  }

  static func probe(_ name: String) -> ProbeSpec? { probes.first { $0.name == name } }
  static func trial(_ name: String) -> TrialSpec? { trials.first { $0.name == name } }
}

enum Dispatcher {
  static var peerCommand: (([String]) -> JSON)?
  static var agentStatus: (() -> JSON)?

  static func run(_ words: [String], emit: (JSON) -> Void) async {
    do { try NumericArguments.validate(words) } catch {
      emit(.obj([("error", .string("\(error)"))]))
      return
    }
    guard let command = words.first else {
      emit(.obj([("error", .string("empty command"))]))
      return
    }
    let rest = Array(words.dropFirst())
    switch command {
    case "ping":
      emit(.obj([("pong", .bool(true)), ("context", RunContext.json)]))
    case "peer-listener":
      emit(peerCommand?(rest) ?? .obj([("error", .string("peer listener requires the agent"))]))
    case "status":
      emit(agentStatus?() ?? .obj([("agent", .bool(false)), ("context", RunContext.json)]))
    case "sample":
      SignalEvents.shared.start()
      let since = rest.first.flatMap(Int.init) ?? SignalEvents.shared.lastSeq
      emit(
        Signals.sample().setting("events", .array(SignalEvents.shared.since(since)))
          .setting("last_seq", .int(SignalEvents.shared.lastSeq)))
    case "act":
      SignalEvents.shared.start()
      emit(await Actions.run(rest))
    case "probe":
      SignalEvents.shared.start()
      await runProbes(rest, emit: emit)
    default:
      emit(.obj([("error", .string("unknown command \(command)"))]))
    }
  }

  static func runProbes(_ words: [String], emit: (JSON) -> Void) async {
    var options = ProbeOptions()
    var names: [String] = []
    var index = 0
    while index < words.count {
      let word = words[index]
      switch word {
      case "--exclude-bundle-id" where index + 1 < words.count:
        options.excludeBundleIDs.append(words[index + 1])
        index += 1
      case "--save-images":
        options.imageDirectory = CaptureTools.imageCacheDirectory
      case "--listener-port" where index + 1 < words.count:
        options.listenerPort = Int(words[index + 1]) ?? options.listenerPort
        index += 1
      default:
        names.append(word)
      }
      index += 1
    }
    if names == ["list"] {
      for spec in Catalog.probes {
        emit(
          .obj([
            ("probe", .string(spec.name)), ("items", .strings(spec.items)),
            ("automatic", .bool(spec.automatic)), ("summary", .string(spec.summary)),
          ]))
      }
      return
    }
    let specs: [ProbeSpec]
    if names == ["all-automatic"] {
      specs = Catalog.probes.filter(\.automatic)
    } else {
      var found: [ProbeSpec] = []
      for name in names {
        guard let spec = Catalog.probe(name) else {
          emit(.obj([("error", .string("unknown probe \(name)"))]))
          return
        }
        found.append(spec)
      }
      specs = found
    }
    for spec in specs {
      let report = await spec.run(options)
      emit(report.json(context: RunContext.json))
    }
  }
}
