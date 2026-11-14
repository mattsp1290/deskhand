import Crypto
import DeskhandCore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct DeskhandTests {
    @Test func versionIsSet() {
        #expect(!Deskhand.version.isEmpty)
    }

    @Test func sha256ComesFromSwiftCrypto() {
        let digest = SHA256.hash(data: Data("abc".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
