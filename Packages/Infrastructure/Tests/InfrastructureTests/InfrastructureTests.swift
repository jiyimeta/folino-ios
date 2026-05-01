@testable import Audio
@testable import CloudSync
@testable import Persistence
@testable import ScoreFiles
@testable import Soundfonts
import Testing

@Suite struct InfrastructureSmokeTests {
    @Test func allModulesLink() {
        #expect(PersistenceModule.isLinked)
        #expect(CloudSyncModule.isLinked)
        #expect(SoundfontsModule.isLinked)
        #expect(AudioModule.isLinked)
        #expect(ScoreFilesModule.isLinked)
    }
}
