import CNIOBoringSSL
import Foundation
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A TLS 1.3 client on BoringSSL itself, because NIOSSL's client can neither keep the session a
/// server issues nor offer one back. It exists to try TLS session resumption against the listener,
/// the way a caller's stack (OpenSSL, Go, Python) would.
///
/// BoringSSL's `SSL_CTX` and `SSL_SESSION` are safe to share between threads, and each exchange
/// runs on a thread of its own with its own `SSL`.
final class ResumingTLSClient: @unchecked Sendable {
    final class Session: @unchecked Sendable {
        fileprivate let pointer: OpaquePointer

        fileprivate init(_ pointer: OpaquePointer) { self.pointer = pointer }

        deinit { SSL_SESSION_free(pointer) }
    }

    struct Exchange: Sendable {
        let resumed: Bool
        let status: Int?
        let issued: Session?
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Sessions the new-session callback received, by the `SSL` they arrived on. The callback is a
    /// C function pointer and cannot capture the client.
    private static let issued = Mutex<[UInt: [UInt]]>([:])

    private let context: OpaquePointer

    init(caPath: String, certificatePath: String?, keyPath: String?) throws {
        guard let context = SSL_CTX_new(TLS_method()) else { throw Failure(description: "SSL_CTX_new failed") }
        self.context = context
        SSL_CTX_set_min_proto_version(context, UInt16(TLS1_3_VERSION))
        SSL_CTX_set_max_proto_version(context, UInt16(TLS1_3_VERSION))
        SSL_CTX_set_verify(context, SSL_VERIFY_PEER, nil)
        guard SSL_CTX_load_verify_locations(context, caPath, nil) == 1 else {
            throw Failure(description: "cannot load the CA")
        }
        if let certificatePath, let keyPath {
            guard SSL_CTX_use_certificate_chain_file(context, certificatePath) == 1,
                SSL_CTX_use_PrivateKey_file(context, keyPath, SSL_FILETYPE_PEM) == 1
            else { throw Failure(description: "cannot load the client identity") }
        }
        SSL_CTX_set_session_cache_mode(context, SSL_SESS_CACHE_CLIENT)
        SSL_CTX_sess_set_new_cb(context) { ssl, session in
            guard let ssl, let session else { return 0 }
            ResumingTLSClient.issued.withLock {
                $0[UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(ssl))), default: []].append(
                    UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(session))))
            }
            return 1
        }
        #if canImport(Glibc)
            // BoringSSL writes to the socket with write(2); a server that already closed must not
            // end the test process.
            signal(SIGPIPE, SIG_IGN)
        #endif
    }

    deinit { SSL_CTX_free(context) }

    /// Connects to loopback `port`, offers `session` if given, sends `request` and reads until the
    /// server closes; every read gives up after 10 seconds. The blocking socket calls run on a
    /// thread of their own: on the cooperative pool they could starve the listener's request
    /// handler, which runs there.
    func exchange(port: Int, serverName: String, request: [UInt8], offering session: Session?, fragmentSize: Int? = nil)
        async throws
        -> Exchange
    {
        try await withCheckedThrowingContinuation { continuation in
            Thread {
                continuation.resume(
                    with: Result {
                        try self.blockingExchange(
                            port: port, serverName: serverName, request: request, offering: session,
                            fragmentSize: fragmentSize)
                    })
            }.start()
        }
    }

    private func blockingExchange(
        port: Int, serverName: String, request: [UInt8], offering session: Session?, fragmentSize: Int? = nil
    ) throws
        -> Exchange
    {
        let socket = try Self.connect(port: port)
        defer { close(socket) }
        guard let ssl = SSL_new(context) else { throw Failure(description: "SSL_new failed") }
        defer {
            let key = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(ssl)))
            for leftover in Self.issued.withLock({ $0.removeValue(forKey: key) }) ?? [] {
                SSL_SESSION_free(OpaquePointer(bitPattern: leftover))
            }
            SSL_free(ssl)
        }
        SSL_set_fd(ssl, socket)
        SSL_set_tlsext_host_name(ssl, serverName)
        if let session { SSL_set_session(ssl, session.pointer) }
        guard SSL_connect(ssl) == 1 else { return Exchange(resumed: false, status: nil, issued: nil) }
        let resumed = SSL_session_reused(ssl) == 1

        let width = fragmentSize ?? max(1, request.count)
        for offset in stride(from: 0, to: request.count, by: width) {
            let bytes = Array(request[offset..<min(offset + width, request.count)])
            let written = bytes.withUnsafeBytes { SSL_write(ssl, $0.baseAddress, Int32($0.count)) }
            if written <= 0 { break }
        }
        var response: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { SSL_read(ssl, $0.baseAddress, Int32($0.count)) }
            guard count > 0 else { break }
            response += buffer[..<Int(count)]
        }

        let key = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(ssl)))
        var sessions = Self.issued.withLock { $0.removeValue(forKey: key) } ?? []
        let first = sessions.isEmpty ? nil : sessions.removeFirst()
        for extra in sessions { SSL_SESSION_free(OpaquePointer(bitPattern: extra)) }
        return Exchange(
            resumed: resumed,
            status: Self.status(of: response),
            issued: first.flatMap { OpaquePointer(bitPattern: $0) }.map(Session.init)
        )
    }

    private static func status(of response: [UInt8]) -> Int? {
        let prefix = Array("HTTP/1.1 ".utf8)
        guard response.count >= prefix.count + 3, Array(response[..<prefix.count]) == prefix else { return nil }
        return Int(String(decoding: response[prefix.count..<prefix.count + 3], as: UTF8.self))
    }

    private static func connect(port: Int) throws -> Int32 {
        #if canImport(Darwin)
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
            let socket = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard socket >= 0 else { throw Failure(description: "socket: errno \(errno)") }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                    Glibc.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard connected == 0 else {
            let code = errno
            close(socket)
            throw Failure(description: "connect: errno \(code)")
        }
        return socket
    }
}
