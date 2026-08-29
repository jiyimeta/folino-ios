import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing
import UtilityCore

extension ReaderGlobalSettingsTests {
    @MainActor
    struct ReaderAnalyticsTests {
        /// The repeat mode is global / sticky (shared `UserDefaults`), so reset it before each test for isolation. That
        /// only isolates against suites nested in the same `.serialized` parent — see `ReaderGlobalSettingsTests`.
        init() {
            UserDefaults.standard.removeObject(forKey: ReaderGlobalSettingsKey.repeatMode)
        }

        private static func makeItem() -> ScoreItem {
            ScoreItem(
                title: "Test", composer: nil, instrumentationSummary: nil,
                localFileName: "test.mscx", contentHash: "hash",
                sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastOpenedAt: nil, tagIDs: [], isFavorite: false,
            )
        }

        private static func makeVM(
            analytics: SpyAnalytics,
            openedFrom: AnalyticsSource = .libraryAll,
        ) -> (ReaderViewModel, FakePlaybackController) {
            let item = Self.makeItem()
            let repo = FakeScoreLibraryRepository()
            repo.scoreItems = [item]
            let controller = FakePlaybackController()
            let vm = ReaderViewModel(
                scoreItem: item,
                repository: repo,
                gateway: FakeScoreFileGateway(),
                scoresDirectory: URL(filePath: "/tmp"),
                playbackController: controller,
                analytics: analytics,
                openedFrom: openedFrom,
            )
            return (vm, controller)
        }

        @Test func `play logs playback_started with layout and origin`() async {
            let spy = SpyAnalytics()
            let (vm, _) = Self.makeVM(analytics: spy, openedFrom: .playlist)
            await vm.load()

            await vm.togglePlayback()

            let event = spy.event(named: "playback_started")
            #expect(event != nil)
            #expect(event?.parameters["from"] == .string("playlist"))
            #expect(event?.parameters["layout_mode"] == .string("page"))
        }

        @Test func `pause logs playback_control`() async {
            let spy = SpyAnalytics()
            let (vm, _) = Self.makeVM(analytics: spy)
            await vm.load()

            await vm.togglePlayback() // start
            await vm.togglePlayback() // pause

            #expect(spy.events.contains {
                $0.name == "playback_control" && $0.parameters["action"] == .string("pause")
            })
        }

        @Test func `reaching the end logs playback_completed`() async {
            let spy = SpyAnalytics()
            let (vm, controller) = Self.makeVM(analytics: spy)
            await vm.load()
            vm.playbackSession.startObservingCursor()
            await vm.togglePlayback()

            controller.emitCursor(nil)
            for _ in 0 ..< 5 {
                await Task.yield()
            }

            #expect(spy.event(named: "playback_completed") != nil)
        }

        @Test func `step forward logs next`() async {
            let spy = SpyAnalytics()
            let (vm, _) = Self.makeVM(analytics: spy)
            await vm.load()

            vm.stepMeasureForward()

            #expect(spy.events.contains { $0.name == "playback_control" && $0.parameters["action"] == .string("next") })
        }

        @Test func `repeat mode change logs repeat_mode_changed`() async {
            let spy = SpyAnalytics()
            let (vm, _) = Self.makeVM(analytics: spy)
            await vm.load()

            await vm.repeatModel.setMode(.loopAll)
            #expect(spy.events.contains {
                $0.name == "repeat_mode_changed" && $0.parameters["mode"] == .string("loop_all")
            })

            // The inspector binds the picker straight to `repeatModel.mode`; the binding write path must log too.
            vm.repeatModel.mode = .abLoop
            #expect(spy.events.contains {
                $0.name == "repeat_mode_changed" && $0.parameters["mode"] == .string("ab_loop")
            })
        }

        @Test func `transpose logs direction up then down`() async {
            let spy = SpyAnalytics()
            let (vm, _) = Self.makeVM(analytics: spy)
            await vm.load()

            await vm.transposeModel.setSemitones(2)
            await vm.transposeModel.setSemitones(1)

            let directions = spy.events
                .filter { $0.name == "transpose_changed" }
                .compactMap { $0.parameters["direction"] }
            #expect(directions == [.string("up"), .string("down")])
        }

        @Test func `tempo logs direction increase then decrease`() async {
            let spy = SpyAnalytics()
            let (vm, _) = Self.makeVM(analytics: spy)
            await vm.load()

            await vm.tempoModel.commitMultiplier(1.5)
            await vm.tempoModel.commitMultiplier(1.2)

            let directions = spy.events
                .filter { $0.name == "tempo_changed" }
                .compactMap { $0.parameters["direction"] }
            #expect(directions == [.string("increase"), .string("decrease")])
        }
    }
}
