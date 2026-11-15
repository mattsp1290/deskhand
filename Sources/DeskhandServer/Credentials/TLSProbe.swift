import NIOCore
import NIOPosix
import NIOSSL
import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum TLSProbe {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func serverContext(_ credentials: ServerTLSCredentials) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: credentials.certificateChain.map { .certificate($0) },
            privateKey: .privateKey(credentials.privateKey)
        )
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        configuration.certificateVerification = .none
        return try NIOSSLContext(configuration: configuration)
    }

    static func handshake(
        server serverContext: NIOSSLContext,
        trustRoots: [NIOSSLCertificate],
        serverName: String,
        group: any EventLoopGroup,
        timeout: TimeAmount
    ) async -> Failure? {
        var client = TLSConfiguration.makeClientConfiguration()
        client.minimumTLSVersion = .tlsv13
        client.maximumTLSVersion = .tlsv13
        client.trustRoots = .certificates(trustRoots)
        client.additionalTrustRoots = []
        client.certificateVerification = .noHostnameVerification
        let clientContext: NIOSSLContext
        do {
            clientContext = try NIOSSLContext(configuration: client)
        } catch {
            return Failure(description: "probe client rejected the CA: \(error)")
        }

        var descriptors: [Int32] = [-1, -1]
        #if canImport(Darwin)
            let socketType = SOCK_STREAM
        #else
            let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        guard socketpair(AF_UNIX, socketType, 0, &descriptors) == 0 else {
            return Failure(description: "socketpair failed (errno \(errno))")
        }
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

        let serverChannel: any Channel
        do {
            serverChannel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: serverContext))
                    }
                }
                .withConnectedSocket(descriptors[0]).get()
        } catch {
            close(descriptors[1])
            return Failure(description: "probe server did not start: \(error)")
        }
        defer { serverChannel.close(promise: nil) }

        let firstError = FirstError()
        let clientChannel: any Channel
        do {
            clientChannel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        try pipeline.addHandler(NIOSSLClientHandler(context: clientContext, serverHostname: serverName))
                        try pipeline.addHandler(ErrorRecorder(firstError))
                    }
                }
                .withConnectedSocket(descriptors[1]).get()
        } catch {
            return Failure(description: "probe client did not start: \(error)")
        }
        defer { clientChannel.close(promise: nil) }

        // NIOSSL holds a write until the handshake completes, and the client completes it only
        // after verifying the server's chain and its signature, so the write's outcome is the
        // handshake's.
        let timer = clientChannel.eventLoop.scheduleTask(in: timeout) { clientChannel.close(promise: nil) }
        defer { timer.cancel() }
        do {
            try await clientChannel.writeAndFlush(ByteBuffer(bytes: [0])).get()
            return nil
        } catch {
            return Failure(description: String(describing: firstError.value ?? error))
        }
    }
}

private final class FirstError: Sendable {
    private let error = Mutex<(any Error)?>(nil)

    var value: (any Error)? { error.withLock { $0 } }

    func record(_ newError: any Error) {
        error.withLock { if $0 == nil { $0 = newError } }
    }
}

private final class ErrorRecorder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let firstError: FirstError

    init(_ firstError: FirstError) { self.firstError = firstError }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        firstError.record(error)
        context.close(promise: nil)
    }
}
