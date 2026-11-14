import DeskhandCore
import DeskhandServer
import DeskhandTestSupport
import NIOCore
import NIOEmbedded
import Testing

@Suite struct DeskhandServerModuleTests {
    @Test func versionMatchesCore() {
        #expect(DeskhandServerModule.version == Deskhand.version)
    }

    @Test func embeddedChannelRoundTripsBytes() throws {
        let channel = EmbeddedChannel()
        try channel.writeOutbound(ByteBuffer(string: "ping"))
        let out = try channel.readOutbound(as: ByteBuffer.self)
        #expect(out == ByteBuffer(string: "ping"))
        #expect(try channel.finish().isClean)
    }
}
