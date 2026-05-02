@testable import Audio
@testable import CloudSync
@testable import Persistence
@testable import ScoreFiles
@testable import Soundfonts
import Testing

@Suite struct InfrastructureSmokeTests {
    @Test func remainingPlaceholderModulesLink() {
        #expect(CloudSyncModule.isLinked)
        #expect(SoundfontsModule.isLinked)
        #expect(AudioModule.isLinked)
        // Persistence's placeholder is gone — its real types are exercised
        // in dedicated tests. ScoreFiles still has a placeholder (deleted in T14).
        #expect(ScoreFilesModule.isLinked)
    }
}
