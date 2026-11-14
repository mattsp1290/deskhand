import DeskhandCore
import Testing

@Suite struct IdentifierTests {
    @Test func acceptsTheContractAlphabets() {
        #expect(HolderID("crew:inst-7f3a:desk-lunus")?.rawValue == "crew:inst-7f3a:desk-lunus")
        #expect(OperationID("call_01HZX3M9Q3.retry-1") != nil)
        #expect(FrameID("frm_Zk3vQ8sN1xT5bYc2Lw9RaA") != nil)
        #expect(BundleID("com.apple.TextEdit") != nil)
    }

    @Test(arguments: ["\n", "\r\n", "\u{85}", " ", "\u{0}"])
    func refusesATrailingLineBreakOrControl(suffix: String) {
        #expect(HolderID("crew" + suffix) == nil)
        #expect(OperationID("c1" + suffix) == nil)
        #expect(FrameID("frm_x" + suffix) == nil)
        #expect(BundleID("com.apple.TextEdit" + suffix) == nil)
    }

    @Test func refusesCharactersOutsideEachAlphabet() {
        #expect(FrameID("frm:x") == nil)
        #expect(FrameID("frm.x") == nil)
        #expect(BundleID("com:apple") == nil)
        #expect(OperationID("has space") == nil)
        #expect(HolderID("café") == nil)
        #expect(HolderID("") == nil)
    }

    @Test func enforcesLengthLimits() {
        #expect(HolderID(String(repeating: "h", count: 128)) != nil)
        #expect(HolderID(String(repeating: "h", count: 129)) == nil)
        #expect(OperationID(String(repeating: "o", count: 129)) == nil)
        #expect(FrameID(String(repeating: "f", count: 64)) != nil)
        #expect(FrameID(String(repeating: "f", count: 65)) == nil)
        #expect(BundleID(String(repeating: "b", count: 255)) != nil)
        #expect(BundleID(String(repeating: "b", count: 256)) == nil)
    }
}
