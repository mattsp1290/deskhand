import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// The `openssl` command line the listener tests run. TLS 1.3 session resumption needs OpenSSL 1.1.1
/// or later: LibreSSL, macOS's `/usr/bin/openssl`, issues sessions but never resumes them.
enum OpenSSLTool {
    static let resumptionRequirement =
        "needs OpenSSL 1.1.1 or later (not LibreSSL) on PATH or at /opt/homebrew/bin, /usr/local/bin or "
        + "/opt/homebrew/opt/openssl@3/bin"

    /// The first OpenSSL 1.1.1 or later found on PATH or in Homebrew's usual places, or `nil`.
    static let resuming: URL? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates =
            path.split(separator: ":").map { "\($0)/openssl" } + [
                "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/opt/homebrew/opt/openssl@3/bin/openssl",
            ]
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first(where: isResumingOpenSSL)
    }()

    /// The binary every test invocation uses: the resuming OpenSSL when there is one, else whatever
    /// `openssl` PATH names, which can still generate certificates.
    static var executable: (url: URL, prefix: [String]) {
        resuming.map { ($0, []) } ?? (URL(fileURLWithPath: "/usr/bin/env"), ["openssl"])
    }

    /// On Linux (CI) the resumption tests always run, so a missing OpenSSL fails them rather than
    /// hiding them.
    static var resumptionTestsEnabled: Bool {
        #if os(Linux)
            true
        #else
            resuming != nil
        #endif
    }

    private static func isResumingOpenSSL(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let process = Process()
        process.executableURL = url
        process.arguments = ["version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer { watchdog.cancel() }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0, text.hasPrefix("OpenSSL ") else {
            return false
        }
        let version = text.dropFirst("OpenSSL ".count).prefix { !$0.isWhitespace }
        let numbers = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        return numbers.lexicographicallyPrecedes([1, 1, 1]) == false
    }
}

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
        let tool = OpenSSLTool.executable
        var arguments = [
            "s_client", "-connect", "127.0.0.1:\(port)", "-servername", TestPKI.serverName,
            "-CAfile", pki.caPath, "-verify_return_error", "-tls1_3", "-ign_eof", "-sess_out", saved.path,
        ]
        if let client {
            let identity = pki.identity(client)
            arguments += ["-cert", identity.certificatePath, "-key", identity.keyPath]
        }
        if let session { arguments += ["-sess_in", session.path] }

        let process = Process()
        process.executableURL = tool.url
        process.arguments = tool.prefix + arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw error
        }
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
