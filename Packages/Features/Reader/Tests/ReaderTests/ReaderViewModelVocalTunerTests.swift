import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
struct ReaderViewModelVocalTunerTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Air", composer: nil, instrumentationSummary: nil,
            localFileName: "Air.mscz", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120,
            primaryKey: nil, addedAt: base, lastOpenedAt: nil,
            tagIDs: [], isFavorite: false,
        )
    }

    private static func makeVM() -> (ReaderViewModel, FakeScoreShareService, FakeVocalTunerHandoff, SpyAnalytics) {
        let share = FakeScoreShareService()
        let handoff = FakeVocalTunerHandoff()
        let analytics = SpyAnalytics()
        let vm = ReaderViewModel(
            scoreItem: makeItem(),
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            shareService: share,
            vocalTunerHandoff: handoff,
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: FakePlaybackController(),
            analytics: analytics,
        )
        return (vm, share, handoff, analytics)
    }

    @Test func `not installed presents the app store and prepares no file`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        handoff.availabilityToReturn = .notInstalled

        await vm.requestVocalTunerHandoff()

        #expect(handoff.presentAppStoreCallCount == 1)
        #expect(share.prepareCallCount == 0)
        #expect(vm.shareTarget == nil)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("app_store"))
    }

    @Test func `handoff capable stages the mscz and takes the deep link`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()

        await vm.requestVocalTunerHandoff()

        #expect(share.requestedFormats == [.museScoreV4])
        #expect(handoff.openScoreCalls.count == 1)
        #expect(handoff.openScoreCalls.first?.displayName == "Air")
        #expect(vm.shareTarget == nil)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("deep_link"))
        #expect(analytics.event(named: "companion_handoff")?.parameters["source"] == .string("reader_overlay"))
    }

    @Test func `share fallback populates the share target`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        handoff.availabilityToReturn = .installedLegacy
        handoff.openScoreResult = .needsShareFallback

        await vm.requestVocalTunerHandoff()

        #expect(vm.shareTarget?.urls == [share.preparedURL])
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("share_fallback"))
    }

    @Test func `export failure logs failed and presents nothing`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        share.prepareError = .scoreParseFailed(reason: "boom")

        await vm.requestVocalTunerHandoff()

        #expect(vm.shareTarget == nil)
        #expect(handoff.openScoreCalls.isEmpty)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("failed"))
    }
}
