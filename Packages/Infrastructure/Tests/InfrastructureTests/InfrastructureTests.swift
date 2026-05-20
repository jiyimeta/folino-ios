@testable import Audio
@testable import CloudSync
@testable import Soundfonts
import Testing

struct InfrastructureSmokeTests {
    @Test func `remaining placeholder modules link`() {
        #expect(CloudSyncModule.isLinked)
    }

    @Test func `real modules expose their root types`() {
        // Audio and Soundfonts now ship real implementations. Touch one type from each to keep the link check honest if
        // someone later strips a target down to a placeholder again.
        _ = GMSoundfontResolver.self
    }
}
