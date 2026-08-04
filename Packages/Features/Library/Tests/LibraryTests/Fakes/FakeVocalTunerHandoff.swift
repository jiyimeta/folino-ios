import Domain
import Foundation

/// Records what the view model asked of the hand-off, and lets a test pin the availability state and the result of
/// the staged open.
@MainActor
final class FakeVocalTunerHandoff: VocalTunerHandoff {
    var availabilityToReturn: VocalTunerAvailability = .installedHandoffCapable
    var openScoreResult: VocalTunerHandoffResult = .openedViaDeepLink
    private(set) var openScoreCalls: [(fileURL: URL, displayName: String)] = []
    private(set) var presentAppStoreCallCount = 0

    var availability: VocalTunerAvailability {
        availabilityToReturn
    }

    func openScore(fileURL: URL, displayName: String) -> VocalTunerHandoffResult {
        openScoreCalls.append((fileURL, displayName))
        return openScoreResult
    }

    func presentAppStore() {
        presentAppStoreCallCount += 1
    }
}
