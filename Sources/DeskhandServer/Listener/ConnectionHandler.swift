import DeskhandCore
import NIOCore
import NIOHTTP1

/// What the TLS verification callback learned about the peer, read by the HTTP handler of the same
/// connection. Both run on the connection's event loop.
final class ConnectionSession {
    var principal: Principal?
}

/// One connection's HTTP side: contract 2.4 checks 2 to 10, the hand-off to the ``RequestHandler``,
/// cancellation on disconnect, the request body deadline and the 5-minute connection cap.
///
/// The socket is read even while a call runs, so a caller hanging up is seen at once and cancels
/// the call (contract 2.1). That rules out NIO's pipelining helper, which stops reading until the
/// response is written. A request pipelined behind a running call is not served: its bytes are
/// dropped and the connection closes after the running call's response.
///
/// Every way the connection can end leads through `enterClosing()`, which cancels a running call:
/// a clean close, a reset, a hang-up without TLS close_notify, the caller closing its sending side,
/// a parse error and each timer. Once the connection is going away nobody can receive the
/// response, so the call must not go on.
final class ConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        case idle
        case receiving(AdmittedHead, ByteBuffer)
        case handling(Task<Void, Never>)
        case closing
    }

    private let screen: RequestScreen
    private let session: ConnectionSession
    private let tokens: any TokenProvider
    private let handler: any RequestHandler
    private let maxResponseBodyBytes: Int
    private let maxAge: TimeAmount
    private let handshakeTimeout: TimeAmount
    private let bodyTimeout: TimeAmount
    private let linger: TimeAmount
    private let events: @Sendable (ListenerEvent) -> Void

    private var state = State.idle
    private var openedAt: NIODeadline?
    private var closeAfterResponse = false
    private var handshakeTimer: Scheduled<Void>?
    private var maxAgeTimer: Scheduled<Void>?
    private var bodyTimer: Scheduled<Void>?
    private var lingerTimer: Scheduled<Void>?

    init(
        configuration: ListenerConfiguration,
        session: ConnectionSession,
        tokens: any TokenProvider,
        handler: any RequestHandler,
        events: @escaping @Sendable (ListenerEvent) -> Void
    ) {
        screen = RequestScreen(configuration)
        self.session = session
        self.tokens = tokens
        self.handler = handler
        maxResponseBodyBytes = configuration.maxResponseBodyBytes
        maxAge = configuration.connectionMaxAge
        handshakeTimeout = configuration.handshakeTimeout
        bodyTimeout = configuration.requestBodyTimeout
        linger = configuration.closeLinger
        self.events = events
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { startTimers(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        startTimers(context: context)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        enterClosing()
        handshakeTimer?.cancel()
        maxAgeTimer?.cancel()
        lingerTimer?.cancel()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .inputClosed? = event as? ChannelEvent {
            close(context: context)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        switch (error as? HTTPParserError, state) {
        case (.some(let parserError), .idle), (.some(let parserError), .receiving):
            let status: HTTPResponseStatus =
                parserError == .headerOverflow ? .requestHeaderFieldsTooLarge : .badRequest
            answerAndClose(status: status, headers: [], context: context)
        default:
            close(context: context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch (unwrapInboundIn(data), state) {
        case (.head(let head), .idle):
            // The verification callback sets the principal before any application data is read,
            // so its absence means the handshake did not authenticate the peer.
            guard session.principal != nil else {
                close(context: context)
                return
            }
            switch screen.screenHead(head, tokens: tokens.acceptedTokens(), now: ContinuousClock.now) {
            case .failure(let refusal):
                answerAndClose(status: refusal.status, headers: refusal.headers, context: context)
            case .success(let admitted):
                let capacity = min(admitted.declaredLength ?? 0, screen.maxBodyBytes)
                state = .receiving(admitted, context.channel.allocator.buffer(capacity: capacity))
                startBodyTimer(context: context)
            }
        case (.head, .handling):
            closeAfterResponse = true
        case (.body(var part), .receiving(let admitted, var body)):
            if let refusal = screen.screenBody(byteCount: body.readableBytes + part.readableBytes) {
                answerAndClose(status: refusal.status, headers: refusal.headers, context: context)
                return
            }
            state = .idle
            body.writeBuffer(&part)
            state = .receiving(admitted, body)
        case (.end, .receiving(let admitted, let body)):
            cancelBodyTimer()
            if let refusal = screen.screenAccept(admitted) {
                answerAndClose(status: refusal.status, headers: refusal.headers, context: context)
                return
            }
            dispatch(admitted, body: body, context: context)
        case (.head, .receiving), (.body, _), (.end, _), (.head, .closing):
            return
        }
    }

    private func dispatch(_ admitted: AdmittedHead, body: ByteBuffer, context: ChannelHandlerContext) {
        guard let principal = session.principal else { return }
        let request = AuthenticatedRequest(
            principal: principal,
            nodeAddress: context.channel.remoteAddress.flatMap(NodeAddress.init(socketAddress:)),
            headers: MCPRequestHeaders(admitted.headers),
            body: Array(body.readableBytesView)
        )
        let handler = self.handler
        let promise = context.eventLoop.makePromise(of: HandlerResponse.self)
        state = .handling(promise.completeWithTask { await handler.handle(request) })
        promise.futureResult.assumeIsolated().whenSuccess { response in
            self.respond(response, to: admitted, context: context)
        }
    }

    private func respond(_ response: HandlerResponse, to admitted: AdmittedHead, context: ChannelHandlerContext) {
        guard case .handling = state, context.channel.isActive else { return }
        var status = response.status
        var body = response.body
        var mustClose = !admitted.keepAlive || closeAfterResponse || isPastMaxAge(now: context.eventLoop.now)
        if let bytes = body, bytes.count > maxResponseBodyBytes {
            events(.responseTooLarge(byteCount: bytes.count))
            status = .internalServerError
            body = nil
            mustClose = true
        }
        var headers = HTTPHeaders()
        if body != nil { headers.add(name: "Content-Type", value: "application/json") }
        headers.add(name: "Content-Length", value: String(body?.count ?? 0))
        headers.add(name: "Connection", value: mustClose ? "close" : "keep-alive")
        let head = HTTPResponseHead(version: admitted.version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let body {
            context.write(
                wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: body)))), promise: nil)
        }
        if mustClose { enterClosing() } else { state = .idle }
        let written = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if mustClose { closeGracefully(after: written, context: context) }
    }

    private func answerAndClose(status: HTTPResponseStatus, headers: [(String, String)], context: ChannelHandlerContext)
    {
        enterClosing()
        var allHeaders = HTTPHeaders(headers)
        allHeaders.add(name: "Content-Length", value: "0")
        allHeaders.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: allHeaders)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        closeGracefully(after: context.writeAndFlush(wrapOutboundOut(.end(nil))), context: context)
    }

    private func enterClosing() {
        if case .handling(let task) = state { task.cancel() }
        state = .closing
        cancelBodyTimer()
    }

    private func close(context: ChannelHandlerContext) {
        enterClosing()
        context.close(promise: nil)
    }

    /// Closing outright while request bytes are still arriving makes the kernel answer them with a
    /// reset, which can destroy the response before the caller reads it. So only the output side is
    /// closed (TLS close_notify, then FIN); whatever the caller still sends is discarded, and the
    /// connection closes when the caller closes its side or after
    /// ``ListenerConfiguration/closeLinger``.
    private func closeGracefully(after written: EventLoopFuture<Void>, context: ChannelHandlerContext) {
        written.assumeIsolated().whenComplete { _ in
            let outputClosed = context.eventLoop.makePromise(of: Void.self)
            context.close(mode: .output, promise: outputClosed)
            outputClosed.futureResult.assumeIsolated().whenFailure { _ in context.close(promise: nil) }
            self.lingerTimer = context.eventLoop.assumeIsolated().scheduleTask(in: self.linger) {
                context.close(promise: nil)
            }
        }
    }

    private func isPastMaxAge(now: NIODeadline) -> Bool {
        guard let openedAt else { return false }
        return now - openedAt >= maxAge
    }

    private func startTimers(context: ChannelHandlerContext) {
        guard openedAt == nil else { return }
        openedAt = context.eventLoop.now
        let loop = context.eventLoop.assumeIsolated()
        // The verification callback sets the principal just before the handshake completes.
        handshakeTimer = loop.scheduleTask(in: handshakeTimeout) {
            guard self.session.principal == nil else { return }
            self.close(context: context)
        }
        maxAgeTimer = loop.scheduleTask(in: maxAge) {
            self.closeAfterResponse = true
            switch self.state {
            case .handling, .closing:
                return
            case .idle, .receiving:
                self.close(context: context)
            }
        }
    }

    private func startBodyTimer(context: ChannelHandlerContext) {
        bodyTimer = context.eventLoop.assumeIsolated().scheduleTask(in: bodyTimeout) {
            guard case .receiving = self.state else { return }
            self.close(context: context)
        }
    }

    private func cancelBodyTimer() {
        bodyTimer?.cancel()
        bodyTimer = nil
    }
}

extension NodeAddress {
    init?(socketAddress: SocketAddress) {
        switch socketAddress {
        case .v4(let address): self.init(bytes: withUnsafeBytes(of: address.address.sin_addr) { Array($0) })
        case .v6(let address): self.init(bytes: withUnsafeBytes(of: address.address.sin6_addr) { Array($0) })
        case .unixDomainSocket: return nil
        }
    }
}
