import Darwin
import Foundation

/// BSD-socket helpers for the LAN listener (the same socket layer SwiftNIO uses) and the agent's
/// owner-only control socket.
public nonisolated enum Net {
  public struct Interface: Sendable {
    public let name: String
    public let address: String
  }

  /// The IPv4 address of the interface that carries the default route.
  public static func lanAddress() -> Interface? {
    let route = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 3)
    let wanted = field("interface", in: route.stdout)
    let addresses = ipv4Addresses()
    if let wanted, let match = addresses.first(where: { $0.name == wanted }) { return match }
    return addresses.first { $0.name.hasPrefix("en") }
  }

  public static func defaultGateway() -> String? {
    field("gateway", in: Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 3).stdout)
  }

  private static func field(_ name: String, in text: String) -> String? {
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if parts.count == 2, parts[0] == name { return parts[1] }
    }
    return nil
  }

  public static func ipv4Addresses() -> [Interface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var result: [Interface] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
        continue
      }
      let flags = Int32(entry.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      let name = String(cString: entry.pointee.ifa_name)
      let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      result.append(Interface(name: name, address: String(decoding: bytes, as: UTF8.self)))
    }
    return result
  }

  public static func errnoName(_ code: Int32) -> String {
    "\(code) \(String(cString: strerror(code)))"
  }

  static func ipv4(_ host: String, _ port: Int) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
    return addr
  }

  /// Connects with a timeout and reads whatever the peer sends first (up to 256 bytes).
  public static func connect(host: String, port: Int, timeoutMs: Int) -> JSON {
    let started = Clock.monoMs()
    func done(_ ok: Bool, _ error: String?, _ greeting: String? = nil) -> JSON {
      .obj([
        ("host", .string(host)), ("port", .int(port)), ("connected", .bool(ok)),
        ("error", .str(error)), ("greeting", .str(greeting)),
        ("elapsed_ms", .int(Int(Clock.monoMs() - started))),
      ])
    }
    guard var addr = ipv4(host, port) else { return done(false, "bad address") }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return done(false, errnoName(errno)) }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let result = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if result != 0 && errno != EINPROGRESS { return done(false, errnoName(errno)) }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, Int32(timeoutMs)) == 1 else { return done(false, "timeout") }
    var soError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
    guard soError == 0 else { return done(false, errnoName(soError)) }
    var readFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    var greeting: String?
    if poll(&readFD, 1, Int32(timeoutMs)) == 1 {
      var buffer = [UInt8](repeating: 0, count: 256)
      let count = read(fd, &buffer, buffer.count)
      if count > 0 { greeting = String(decoding: buffer.prefix(count), as: UTF8.self) }
    }
    return done(true, nil, greeting?.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func writeAll(_ fd: Int32, _ text: String) {
    var bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeMutableBytes { write(fd, $0.baseAddress, $0.count) }
      if written <= 0 { return }
      offset += written
    }
    bytes.removeAll()
  }

  static func readLine(_ fd: Int32, limit: Int = 4096) -> String? {
    var data: [UInt8] = []
    var byte: UInt8 = 0
    while data.count < limit {
      let count = read(fd, &byte, 1)
      if count <= 0 { break }
      if byte == 10 { return String(decoding: data, as: UTF8.self) }
      data.append(byte)
    }
    return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
  }
}

/// A TCP listener on one address. Every accepted connection gets a one-line greeting and is
/// closed; `onAccept` reports the peer.
public nonisolated final class TCPListener: @unchecked Sendable {
  public let host: String
  public let port: Int
  private var fd: Int32 = -1

  public init(host: String, port: Int) {
    self.host = host
    self.port = port
  }

  /// Binds and starts accepting on a background thread. Returns an error text on failure.
  public func start(
    greeting: @escaping @Sendable () -> String,
    onAccept: @escaping @Sendable (_ peer: String) -> Void
  ) -> String? {
    guard var addr = Net.ipv4(host, port) else { return "bad address \(host)" }
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return Net.errnoName(errno) }
    var yes: Int32 = 1
    setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(socketFD, 16) == 0 else {
      let error = Net.errnoName(errno)
      close(socketFD)
      return error
    }
    fd = socketFD
    Thread.detachNewThread {
      while true {
        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &peer) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(socketFD, $0, &length) }
        }
        if client < 0 {
          if errno == EINTR { continue }
          return
        }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &peer.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        let bytes = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let peerText = String(decoding: bytes, as: UTF8.self) + ":\(UInt16(bigEndian: peer.sin_port))"
        Net.writeAll(client, greeting() + "\n")
        close(client)
        onAccept(peerText)
      }
    }
    return nil
  }

  public func stop() {
    if fd >= 0 {
      close(fd)
      fd = -1
    }
  }
}

/// The agent's control socket: a Unix-domain socket in an owner-only directory. A client sends
/// one line of space-separated words and reads lines until the agent closes the connection.
public nonisolated final class ControlServer: @unchecked Sendable {
  public typealias Handler = @MainActor @Sendable (
    _ words: [String], _ emit: @escaping @Sendable (String) -> Void
  ) async -> Void

  public static var defaultPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/homes.birb.deskhand/spike/control.sock")
      .path
  }

  private let path: String
  private var fd: Int32 = -1

  public init(path: String = ControlServer.defaultPath) {
    self.path = path
  }

  public func start(handler: @escaping Handler) -> String? {
    let directory = (path as NSString).deletingLastPathComponent
    do {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    } catch {
      return "control directory: \(error)"
    }
    unlink(path)
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return Net.errnoName(errno) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      close(socketFD)
      return "socket path too long"
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(socketFD, 8) == 0 else {
      let error = Net.errnoName(errno)
      close(socketFD)
      return error
    }
    chmod(path, 0o600)
    fd = socketFD
    Thread.detachNewThread {
      while true {
        let client = accept(socketFD, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          return
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
          close(client)
          continue
        }
        DispatchQueue.global().async {
          let words = (Net.readLine(client) ?? "").split(separator: " ").map(String.init)
          let emit: @Sendable (String) -> Void = { line in Net.writeAll(client, line + "\n") }
          Task { @MainActor in
            await handler(words, emit)
            close(client)
          }
        }
      }
    }
    return nil
  }
}

/// The trial driver's side of the control socket.
public nonisolated enum ControlClient {
  public static func available(path: String = ControlServer.defaultPath) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  /// Sends `words` and streams every reply line to `onLine` until the agent closes.
  public static func call(
    _ words: [String], path: String = ControlServer.defaultPath,
    onLine: @escaping @Sendable (String) -> Void
  ) async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: blockingCall(words, path: path, onLine: onLine))
      }
    }
  }

  private static func blockingCall(
    _ words: [String], path: String, onLine: (String) -> Void
  ) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return Net.errnoName(errno) }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      return "socket path too long"
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { return "agent not reachable: \(Net.errnoName(errno))" }
    Net.writeAll(fd, words.joined(separator: " ") + "\n")
    var pending: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count <= 0 { break }
      pending.append(contentsOf: buffer[0..<count])
      while let newline = pending.firstIndex(of: 10) {
        onLine(String(decoding: pending[..<newline], as: UTF8.self))
        pending.removeSubrange(...newline)
      }
    }
    if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
    return nil
  }
}
