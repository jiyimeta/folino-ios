import Domain
import Foundation
@testable import Library
import Testing

@MainActor
struct LibraryViewModelVocalTunerTests {
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

    private static func makeVM() -> (LibraryViewModel, FakeScoreShareService, FakeVocalTunerHandoff, SpyAnalytics) {
        let share = FakeScoreShareService()
        let handoff = FakeVocalTunerHandoff()
        let analytics = SpyAnalytics()
        let vm = LibraryViewModel(
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            importer: FakeScoreFileImporter(),
            gateway: FakeScoreFileGateway(),
            shareService: share,
            metadataReader: FakeScoreMetadataReading(),
            creator: FakeScoreFileCreator(),
            scoresDirectory: URL(filePath: "/tmp/folino-tests"),
            vocalTunerHandoff: handoff,
            analytics: analytics,
        )
        return (vm, share, handoff, analytics)
    }

    @Test func `not installed presents the app store and prepares no file`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        handoff.availabilityToReturn = .notInstalled

        await vm.requestVocalTunerHandoff(Self.makeItem())

        #expect(handoff.presentAppStoreCallCount == 1)
        #expect(share.prepareShareCalls.isEmpty)
        #expect(vm.shareTarget == nil)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("app_store"))
    }

    @Test func `handoff capable stages the mscz and takes the deep link`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/Air.mscz")

        await vm.requestVocalTunerHandoff(Self.makeItem())

        #expect(share.prepareShareCalls.first?.format == .museScoreV4)
        #expect(handoff.openScoreCalls.first?.displayName == "Air")
        #expect(handoff.openScoreCalls.first?.fileURL == URL(fileURLWithPath: "/tmp/share/Air.mscz"))
        #expect(vm.shareTarget == nil)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("deep_link"))
        #expect(analytics.event(named: "companion_handoff")?.parameters["target"] == .string("vocaltuner"))
    }

    @Test func `share fallback populates the share target`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        handoff.availabilityToReturn = .installedLegacy
        handoff.openScoreResult = .needsShareFallback
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/Air.mscz")

        await vm.requestVocalTunerHandoff(Self.makeItem())

        #expect(vm.shareTarget?.urls == [URL(fileURLWithPath: "/tmp/share/Air.mscz")])
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("share_fallback"))
    }

    @Test func `export failure surfaces an error and logs failed`() async {
        let (vm, share, handoff, analytics) = Self.makeVM()
        share.prepareShareError = .scoreParseFailed(reason: "boom")

        await vm.requestVocalTunerHandoff(Self.makeItem())

        #expect(vm.currentError != nil)
        #expect(handoff.openScoreCalls.isEmpty)
        #expect(analytics.event(named: "companion_handoff")?.parameters["outcome"] == .string("failed"))
    }

    @Test func `is preparing share toggles around the handoff`() async {
        let (vm, share, _, _) = Self.makeVM()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/Air.mscz")
        await vm.requestVocalTunerHandoff(Self.makeItem())
        #expect(vm.isPreparingShare == false)
    }
}
