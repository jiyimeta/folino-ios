@testable import Audio
@testable import CloudSync
@testable import Soundfonts
import Testing

@Suite struct InfrastructureSmokeTests {
    @Test func remainingPlaceholderModulesLink() {
        #expect(CloudSyncModule.isLinked)
    }

    @Test func realModulesExposeTheirRootTypes() {
        // Audio and Soundfonts now ship real implementations. Touch one
        // type from each to keep the link check honest if someone later
        // strips a target down to a placeholder again.
        _ = BundleSoundfontResolver.self
        _ = MuseScoreSF2Resolver.self
    }
}
