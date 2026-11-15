import Foundation
import NIOCore
import NIOHTTP1

enum BoundedHTTPCodec {
    static func install(on channel: any Channel, limit: Int) throws {
        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldSize = limit
        limits.maxHeaderListSize = limit
        let framing = Framing(limit: limit)
        let pipeline = channel.pipeline.syncOperations
        try pipeline.addHandler(Feeder(framing))
        try pipeline.addHandler(
            ByteToMessageHandler(
                HTTPRequestDecoder(
                    leftOverBytesStrategy: .dropBytes, limitConfiguration: limits)))
        try pipeline.addHandler(HTTPResponseEncoder())
        try pipeline.addHandler(Observer(framing))
    }

    private final class Framing {
        enum Phase {
            case headers(Int)
            case fixed(UInt64)
            case chunkLine(UInt64, prefix: Bool)
            case chunkData(UInt64)
            case chunkTerminator
            case trailers
            case awaitingEnd
            case closed
        }
        let limit: Int
        var phase: Phase = .headers(0)
        init(limit: Int) { self.limit = limit }

        func head(_ head: HTTPRequestHead) {
            guard case .headers = phase else { return }
            // llhttp rejects request transfer encodings without a final chunked coding
            // synchronously after the head callback, before the feeder can continue.
            if head.headers.contains(name: "transfer-encoding") {
                phase = .chunkLine(0, prefix: true)
            } else if let value = head.headers["content-length"].first,
                let length = UInt64(value.trimmingCharacters(in: .whitespaces)), length > 0
            {
                phase = .fixed(length)
            } else {
                phase = .awaitingEnd
            }
        }

        func end() {
            if case .closed = phase { return }
            phase = .headers(0)
        }

        func sliceLength(_ buffer: ByteBuffer) throws -> Int {
            let bytes = buffer.readableBytesView
            func lineLength() -> Int {
                bytes.firstIndex(of: 10).map { bytes.distance(from: bytes.startIndex, to: $0) + 1 } ?? bytes.count
            }
            switch phase {
            case .headers(let count):
                let available = limit - count
                guard available > 0 else { throw HTTPParserError.headerOverflow }
                let size = min(lineLength(), available)
                phase = .headers(count + size)
                return size
            case .fixed(let remaining):
                let size = Int(min(remaining, UInt64(bytes.count)))
                phase = remaining == UInt64(size) ? .awaitingEnd : .fixed(remaining - UInt64(size))
                return size
            case .chunkData(let remaining):
                let size = Int(min(remaining, UInt64(bytes.count)))
                phase = remaining == UInt64(size) ? .chunkTerminator : .chunkData(remaining - UInt64(size))
                return size
            case .chunkLine(var size, var prefix):
                let lineCount = lineLength()
                for byte in bytes.prefix(lineCount) {
                    if prefix {
                        let digit: UInt64?
                        switch byte {
                        case 48...57: digit = UInt64(byte - 48)
                        case 65...70: digit = UInt64(byte - 55)
                        case 97...102: digit = UInt64(byte - 87)
                        default: digit = nil
                        }
                        if let digit {
                            let multiplied = size.multipliedReportingOverflow(by: 16)
                            let added = multiplied.partialValue.addingReportingOverflow(digit)
                            if multiplied.overflow || added.overflow {
                                prefix = false
                            } else {
                                size = added.partialValue
                            }
                        } else {
                            prefix = false
                        }
                    }
                }
                phase =
                    bytes.prefix(lineCount).last == 10
                    ? (size == 0 ? .trailers : .chunkData(size)) : .chunkLine(size, prefix: prefix)
                return lineCount
            case .chunkTerminator:
                let lineCount = lineLength()
                if bytes.prefix(lineCount).last == 10 { phase = .chunkLine(0, prefix: true) }
                return lineCount
            case .trailers: return lineLength()
            case .awaitingEnd: throw HTTPParserError.invalidInternalState
            case .closed: return 0
            }
        }
    }

    private final class Feeder: ChannelDuplexHandler {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer
        typealias OutboundIn = ByteBuffer
        let framing: Framing
        init(_ framing: Framing) { self.framing = framing }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            do {
                while buffer.readableBytes > 0 {
                    let count = try framing.sliceLength(buffer)
                    guard count > 0 else { return }
                    let slice = buffer.readSlice(length: count)!
                    context.fireChannelRead(wrapInboundOut(slice))
                }
            } catch {
                framing.phase = .closed
                context.fireErrorCaught(error)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            framing.phase = .closed
            context.fireChannelInactive()
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case .inputClosed? = event as? ChannelEvent { framing.phase = .closed }
            context.fireUserInboundEventTriggered(event)
        }

        func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            framing.phase = .closed
            context.close(mode: mode, promise: promise)
        }
    }

    private final class Observer: ChannelDuplexHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias InboundOut = HTTPServerRequestPart
        typealias OutboundIn = HTTPServerResponsePart
        typealias OutboundOut = HTTPServerResponsePart
        let framing: Framing
        init(_ framing: Framing) { self.framing = framing }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head): framing.head(head)
            case .end: framing.end()
            case .body: break
            }
            context.fireChannelRead(data)
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            framing.phase = .closed
            context.fireErrorCaught(error)
        }

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            if case .head(let head) = unwrapOutboundIn(data), !head.isKeepAlive { framing.phase = .closed }
            context.write(data, promise: promise)
        }
    }
}
