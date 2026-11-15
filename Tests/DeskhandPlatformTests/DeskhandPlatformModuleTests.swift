import DeskhandCore
import DeskhandPlatform
import DeskhandTestSupport
import Testing

@Suite struct DeskhandPlatformModuleTests {
    @Test func versionMatchesCore() {
        #expect(DeskhandPlatformModule.version == Deskhand.version)
    }
}
