import Foundation

public nonisolated enum PeerEvidence {
  public static func correlated(target: JSON, peer: JSON) -> Bool {
    guard let nonce = target["nonce"]?.stringValue, UUID(uuidString: nonce) != nil,
      let address = target["address"]?.stringValue,
      let port = target["port"]?.intValue,
      let targetHost = target["target_host"]?.stringValue,
      let sourceHost = peer["source_host"]?.stringValue, sourceHost != targetHost,
      let localAddress = peer["local_address"]?.stringValue, localAddress != address,
      let localPort = peer["local_port"]?.intValue,
      peer["host"]?.stringValue == address, peer["port"]?.intValue == port,
      peer["connected"]?.boolValue == true, peer["expected_nonce"]?.stringValue == nonce,
      let greeting = peer["greeting"]?.stringValue.flatMap(JSON.parse),
      greeting["nonce"]?.stringValue == nonce, greeting["target_host"]?.stringValue == targetHost
    else { return false }
    return target["accepted"]?.arrayValue?.contains {
      $0["nonce"]?.stringValue == nonce && $0["peer"]?.stringValue == "\(localAddress):\(localPort)"
        && $0["t"]?["mono_ms"]?.doubleValue != nil
    } == true
  }
}
