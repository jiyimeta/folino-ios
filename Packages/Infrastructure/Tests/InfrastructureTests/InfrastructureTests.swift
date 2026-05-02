@testable import Audio
@testable import CloudSync
@testable import Soundfonts
import Testing

@Suite struct InfrastructureSmokeTests {
    @Test func remainingPlaceholderModulesLink() {
        #expect(CloudSyncModule.isLinked)
        #expect(SoundfontsModule.isLinked)
        #expect(AudioModule.isLinked)
    }
}
