import Foundation
import SpikeKit

/// Item 9: an inbound TCP listener bound to the LAN address (as deskhand v0 binds it), a
/// same-host connection to it, the agent's own listener, and an outbound LAN connection to the
/// gateway (the usual symptom of a Local Network denial is EHOSTUNREACH). Inbound from another
/// host needs the peer Mac or the Lima guest (run-spike.sh --remote, bean ealq).
enum ListenerProbe {
  static let spec = ProbeSpec(
    name: "listener", items: ["9"],
    summary: "LAN listener bind/accept, agent listener reachability, outbound LAN connect",
    run: run)

  private final class Peers: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var all: [String] { lock.withLock { stored } }
    func add(_ peer: String) { lock.withLock { stored.append(peer) } }
  }

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("listener", items: spec.items)
    guard let lan = Net.lanAddress() else {
      report.fail("no IPv4 LAN address")
      return report
    }
    let gateway = Net.defaultGateway()
    report.set("lan", .obj([("interface", .string(lan.name)), ("address", .string(lan.address))]))
    report.set("gateway", .str(gateway))
    let windowsBefore = alertOwners()

    let port = options.listenerPort + 1
    let listener = TCPListener(host: lan.address, port: port)
    let peers = Peers()
    let bindError = listener.start(
      greeting: { "deskhand-spike probe" }, onAccept: { peer in peers.add(peer) })
    report.set("probe_listener_bind", .obj([("port", .int(port)), ("error", .str(bindError))]))
    if bindError == nil {
      let address = lan.address
      let connect = await Task.detached { Net.connect(host: address, port: port, timeoutMs: 2000) }
        .value
      await settle(ms: 200)
      listener.stop()
      report.set("probe_listener_self_connect", connect)
      report.set("probe_listener_accepted", .strings(peers.all))
      report.finding(
        "own listener on \(lan.address):\(port): same-host connect "
          + "\(connect["connected"]?.boolValue == true ? "succeeded" : "FAILED (\(connect["error"]?.stringValue ?? "?"))")")
    } else {
      report.finding("own listener on \(lan.address):\(port): bind failed: \(bindError ?? "")")
    }

    let agentPort = options.listenerPort
    let address = lan.address
    let agent = await Task.detached { Net.connect(host: address, port: agentPort, timeoutMs: 2000) }
      .value
    report.set("agent_listener_connect", agent)
    report.finding(
      "agent listener \(lan.address):\(agentPort): "
        + (agent["connected"]?.boolValue == true
          ? "reachable, greeting \(agent["greeting"]?.stringValue ?? "none")" : "not reachable"))

    if let gateway {
      var outbound: [JSON] = []
      for gatewayPort in [53, 80] {
        outbound.append(
          await Task.detached { Net.connect(host: gateway, port: gatewayPort, timeoutMs: 2000) }
            .value)
      }
      report.set("outbound_gateway", .array(outbound))
      let summary = outbound.map {
        "\($0["port"]?.intValue ?? 0): "
          + ($0["connected"]?.boolValue == true ? "ok" : ($0["error"]?.stringValue ?? "?"))
      }
      report.finding("outbound to gateway \(gateway): " + summary.joined(separator: ", "))
    }
    await settle(ms: 1500)
    let windowsAfter = alertOwners()
    let appeared = windowsAfter.subtracting(windowsBefore)
    report.set("alert_window_owners_appeared", .strings(appeared.sorted()))
    if !appeared.isEmpty {
      report.finding("new alert-level windows after the network attempts: \(appeared.sorted())")
    }
    report.needsHuman = true
    report.note(
      "a Local Network prompt is confirmed by a person (trial permissions); inbound from another "
        + "host: run-spike.sh --remote, Lima guest: bean deskhand-ealq")
    return report
  }

  /// Owners of on-screen windows at or above the modal-panel level (where consent prompts sit).
  static func alertOwners() -> Set<String> {
    let level = Int(CGWindowLevelForKey(.modalPanelWindow))
    return Set(
      WindowList.onScreen().filter { ($0.layer ?? 0) >= level }.compactMap(\.ownerName))
  }
}
