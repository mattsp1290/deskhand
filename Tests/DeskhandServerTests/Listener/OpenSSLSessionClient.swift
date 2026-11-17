import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Tries TLS 1.3 session resumption through `openssl s_client`, the way a caller's stack would.
/// NIOSSL's client can neither keep the session a server issues nor offer one back, and BoringSSL
/// itself is not a product swift-nio-ssl exports.
struct OpenSSLSessionClient: Sendable {
    struct Exchange: Sendable {
        let status: Int?
        let resumed: Bool
        /// The session file the server's ticket was saved to, or `nil` when none arrived.
        let issued: URL?
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let pki: TestPKI
    let client: TestPKI.Client?

    /// Connects to loopback `port`, offers the session saved at `session` if given, sends `request`
    /// and reads until the server closes. A new ticket is saved to a fresh file. `s_client` is killed
    /// after 10 seconds.
    func exchange(port: Int, request: [UInt8], offering session: URL? = nil) async throws -> Exchange {
        try await withCheckedThrowingContinuation { continuation in
            Thread {
                continuation.resume(
                    with: Result { try blockingExchange(port: port, request: request, offering: session) })
            }.start()
        }
    }

    private func blockingExchange(port: Int, request: [UInt8], offering session: URL?) throws -> Exchange {
        let saved = pki.directory.appendingPathComponent("session-\(UUID().uuidString).pem")
        var arguments = [
            "openssl", "s_client", "-connect", "127.0.0.1:\(port)", "-servername", TestPKI.serverName,
            "-CAfile", pki.caPath, "-verify_return_error", "-tls1_3", "-ign_eof", "-sess_out", saved.path,
        ]
        if let client {
            let identity = pki.identity(client)
            arguments += ["-cert", identity.certificatePath, "-key", identity.keyPath]
        }
        if let session { arguments += ["-sess_in", session.path] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let ticket = (try? Data(contentsOf: saved)).map { !$0.isEmpty } == true
        return Exchange(
            status: Self.status(in: text), resumed: text.contains("\nReused, "), issued: ticket ? saved : nil)
    }

    private static func status(in output: String) -> Int? {
        guard let line = output.range(of: "HTTP/1.1 ") else { return nil }
        return Int(output[line.upperBound...].prefix(3))
    }
}

/// A TLS 1.3 server that shares one context across connections, so it resumes any session it
/// issued. It answers every connection with an empty 200 and closes. Resuming against it shows
/// that ``OpenSSLSessionClient`` can resume at all.
struct ResumingTestServer {
    let channel: any Channel

    var port: Int { channel.localAddress!.port! }

    static func withServer<Result>(pki: TestPKI, _ body: (ResumingTestServer) async throws -> Result) async throws
        -> Result
    {
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMFile(pki.serverCertificatePath).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: pki.serverKeyPath, format: .pem)))
        tls.minimumTLSVersion = .tlsv13
        let context = try NIOSSLContext(configuration: tls)
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(NIOSSLServerHandler(context: context))
                    try pipeline.addHandler(Answer())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            let result = try await body(ResumingTestServer(channel: channel))
            try await channel.close()
            return result
        } catch {
            try? await channel.close()
            throw error
        }
    }

    private final class Answer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private var answered = false

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !answered else { return }
            answered = true
            let response = ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            context.writeAndFlush(wrapOutboundOut(response), promise: nil)
            context.close(promise: nil)
        }
    }
}
