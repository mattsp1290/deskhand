import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import DeskhandServer

@Suite struct BoundedHTTPCodecTests {
    private static func decode(_ bytes: [UInt8], split: Int, bounded: Bool) throws -> [String] {
        let channel = EmbeddedChannel()
        if bounded {
            try BoundedHTTPCodec.install(on: channel, limit: 16_384)
        } else {
            try channel.pipeline.syncOperations.addHandler(
                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)))
        }
        var result: [String] = []
        var body: [UInt8] = []
        func drain() throws {
            while let part = try channel.readInbound(as: HTTPServerRequestPart.self) {
                switch part {
                case .head(let head): result.append("head \(head.method) \(head.uri) \(head.headers)")
                case .body(let buffer): body += buffer.readableBytesView
                case .end(let trailers):
                    result.append("body \(body)")
                    body = []
                    result.append("end \(String(describing: trailers))")
                }
            }
        }
        do {
            if split > 0 { try channel.writeInbound(ByteBuffer(bytes: bytes[..<split])) }
            try drain()
            if split < bytes.count { try channel.writeInbound(ByteBuffer(bytes: bytes[split...])) }
            try drain()
            _ = try channel.finish()
        } catch {
            try drain()
            result.append("error \(error)")
            _ = try? channel.finish()
        }
        try drain()
        if !body.isEmpty { result.append("partial \(body)") }
        return result
    }

    @Test func parserAgreementAtEverySplitAndEOF() throws {
        let next = "POST /next HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let heads = [
            "Content-Length: 3", "Content-Length: 0003", "Content-Length: 3\r\nContent-Length: 3",
            "Content-Length: 3\r\nContent-Length: 4", "Content-Length: 18446744073709551615",
            "Content-Length: 18446744073709551616", "Content-Length: +3",
            "Content-Length: 0000000000000000000000000003", "Content-Length: 3 \t", "Content-Length: 3, 3",
            "Transfer-Encoding: chunked", "Transfer-Encoding: ChUnKeD", "Transfer-Encoding: gzip, chunked",
            "Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked",
            "Transfer-Encoding: chunked\r\nTransfer-Encoding: gzip",
            "Transfer-Encoding: chunked\r\nContent-Length: 3", "Transfer-Encoding: gzip",
            "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked", "Transfer-Encoding: gzip\r\n chunked",
            "Transfer-Encoding: chunked, gzip", "Transfer-Encoding: gzip ,\tchunked \t",
        ]
        var corpus = heads.map {
            "POST /mcp HTTP/1.1\r\n\($0)\r\n\r\n" + ($0.contains("Transfer") ? "3\r\nabc\r\n0\r\n\r\n" : "abc") + next
        }
        let prefix = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        for chunk in [
            "0003", "3;x=y", "3;x=\"a\\\"b\"", "3;x=\"a;b\";z=q", "3 ;x=y", "FFFFFFFFFFFFFFFF", "10000000000000000",
            "x",
        ] {
            corpus.append(prefix + chunk + "\r\nabc\r\n0;done=yes\r\nX-Trailer: value\r\n\r\n" + next)
        }
        corpus += [
            next, next + next, prefix + "1\r\nx\r\n0\r\n\r\n", prefix + "3\nabc\n0\n\n",
            next.replacingOccurrences(of: "\r\n", with: "\n"), next.replacingOccurrences(of: "\r\n", with: "\r"),
        ]
        let payload = "POST /fake HTTP/1.1\r\n\r\n"
        corpus.append(prefix + String(payload.utf8.count, radix: 16) + "\r\n" + payload + "\r\n0\r\n\r\n" + next)
        for wire in corpus {
            let bytes = Array(wire.utf8)
            for split in 0...bytes.count {
                let original = try Self.decode(bytes, split: split, bounded: false)
                let bounded = try Self.decode(bytes, split: split, bounded: true)
                #expect(
                    bounded == original,
                    "wire=\(wire.debugDescription) split=\(split) actual=\(bounded) expected=\(original)")
            }
        }
        for wire in corpus {
            let bytes = Array(wire.utf8)
            for end in 0...bytes.count {
                let prefix = Array(bytes.prefix(end))
                #expect(
                    try Self.decode(prefix, split: end, bounded: true)
                        == Self.decode(prefix, split: end, bounded: false))
            }
        }
    }

    @Test func chunkExtensionsHaveNoNewLengthCap() throws {
        let wire =
            "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1;x="
            + String(repeating: "a", count: 20_000) + "\r\nx\r\n0\r\n\r\n"
        let bytes = Array(wire.utf8)
        for split in [0, 1, 16_384, 20_000, bytes.count] {
            #expect(
                try Self.decode(bytes, split: split, bounded: true) == Self.decode(bytes, split: split, bounded: false))
        }
    }

    @Test func rawHeaderLimitCountsDiscardedWhitespace() throws {
        let prefix = "POST /mcp HTTP/1.1\r\nX:"
        for extra in [0, 1] {
            let wire = prefix + String(repeating: " ", count: 16_384 - prefix.utf8.count - 5 + extra) + "x\r\n\r\n"
            let result = try Self.decode(Array(wire.utf8), split: 100, bounded: true)
            #expect(result.contains(where: { $0.contains("overflow detected") }) == (extra == 1))
            #expect(result.contains(where: { $0.hasPrefix("head") }) == (extra == 0))
        }
        let incomplete = prefix + String(repeating: " ", count: 20_000)
        #expect(
            try Self.decode(Array(incomplete.utf8), split: 1, bounded: true).contains(where: {
                $0.contains("overflow detected")
            }))
    }
}
