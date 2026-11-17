import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Synchronization

/// A TLS 1.3 client that writes raw bytes, optionally one TLS record per fragment, and reads until
/// the server closes, so a test can put bytes on the wire that an HTTP client never would.
struct RawTLSClient: Sendable {
    struct Exchange: Sendable {
        let bytes: [UInt8]
        let status: Int?
    }

    private struct Closed: Error {}

    private let context: NIOSSLContext

    init(pki: TestPKI, as client: TestPKI.Client? = .valid) throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([pki.caCertificate])
        tls.certificateVerification = .fullVerification
        tls.minimumTLSVersion = .tlsv13
        tls.maximumTLSVersion = .tlsv13
        if let client {
            let identity = pki.identity(client)
            tls.certificateChain = [.certificate(identity.certificate)]
            tls.privateKey = .privateKey(identity.key)
        }
        context = try NIOSSLContext(configuration: tls)
    }

    /// Sends `request` after the handshake, in flushed writes of `fragmentSize` bytes when given, and
    /// collects what the server sends until it closes. A failed handshake gives no bytes. The
    /// connection is abandoned after 10 seconds without a completed write or a read, or after 60 in all.
    func exchange(to address: SocketAddress, request: [UInt8], fragmentSize: Int? = nil) async throws -> Exchange {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let handshake = loop.makePromise(of: Void.self)
        let closed = loop.makePromise(of: [UInt8].self)
        let lastProgress = Progress()
        let context = self.context
        let channel = try await ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(NIOSSLClientHandler(context: context, serverHostname: TestPKI.serverName))
                    try pipeline.addHandler(Collector(handshake: handshake, closed: closed, progress: lastProgress))
                }
            }
            .connect(to: address).get()
        let giveUp = NIODeadline.now() + .seconds(60)
        let watchdog = loop.scheduleRepeatedTask(initialDelay: .milliseconds(250), delay: .milliseconds(250)) { _ in
            let now = NIODeadline.now()
            if now > giveUp || now - lastProgress.last > .seconds(10) { channel.close(promise: nil) }
        }
        defer { watchdog.cancel() }

        if (try? await handshake.futureResult.get()) != nil {
            let width = fragmentSize ?? max(1, request.count)
            for offset in stride(from: 0, to: request.count, by: width) {
                let fragment = ByteBuffer(bytes: request[offset..<min(offset + width, request.count)])
                guard (try? await channel.writeAndFlush(fragment).get()) != nil else { break }
                lastProgress.touch()
            }
        }
        let bytes = try await closed.futureResult.get()
        return Exchange(bytes: bytes, status: Self.status(of: bytes))
    }

    private static func status(of response: [UInt8]) -> Int? {
        let prefix = Array("HTTP/1.1 ".utf8)
        guard response.count >= prefix.count + 3, Array(response[..<prefix.count]) == prefix else { return nil }
        return Int(String(decoding: response[prefix.count..<prefix.count + 3], as: UTF8.self))
    }

    private final class Progress: Sendable {
        private let instant = Mutex(NIODeadline.now())

        var last: NIODeadline { instant.withLock { $0 } }

        func touch() { instant.withLock { $0 = .now() } }
    }

    private final class Collector: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        private let handshake: EventLoopPromise<Void>
        private let closed: EventLoopPromise<[UInt8]>
        private var bytes: [UInt8] = []
        private let progress: Progress
        private var shookHands = false

        init(handshake: EventLoopPromise<Void>, closed: EventLoopPromise<[UInt8]>, progress: Progress) {
            self.handshake = handshake
            self.closed = closed
            self.progress = progress
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case .handshakeCompleted = event as? TLSUserEvent, !shookHands {
                shookHands = true
                handshake.succeed()
            }
            context.fireUserInboundEventTriggered(event)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            bytes += unwrapInboundIn(data).readableBytesView
            progress.touch()
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            if !shookHands { handshake.fail(Closed()) }
            closed.succeed(bytes)
            context.fireChannelInactive()
        }
    }
}
