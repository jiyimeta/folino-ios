import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

/// Verifies `ReaderPlaybackSession.togglePlayback()` forwards the user's global count-in preference into
/// `PlaybackController.play(countIn:)` — the whole of the Folino-side orchestration described in the design's
/// §5 ("Folino side (thin)"): a single `countIn:` flag, no separate player, no `isPrecounting`.
@MainActor
struct ReaderPlaybackSessionPrecountTests {
    private static func twoMeasureScore() -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [Measure(voices: []), Measure(voices: [])])],
        )
        let systemMeasures = [
            SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2.0))),
            ]),
            SystemMeasure(),
        ]
        return Score(division: 480, parts: [part], systemMeasures: systemMeasures, metaTags: [:])
    }

    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: "t.mscx", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func session(
        controller: FakePlaybackController,
    ) -> ReaderPlaybackSession {
        let score = twoMeasureScore()
        let item = Self.makeItem()
        let session = ReaderPlaybackSession(controller: controller, museScoreGeneralProvider: nil)
        session.scoreProvider = { score }
        session.scoreItemProvider = { item }
        session.preferencesProvider = {
            ReaderPreferences(scoreItemID: item.id, staffSize: 14, hiddenStaves: [])
        }
        return session
    }

    @Test func `toggle playback with precount enabled plays with count-in`() async {
        let controller = FakePlaybackController()
        let session = Self.session(controller: controller)
        session.isPrecountEnabled = { true }

        await session.togglePlayback()

        #expect(controller.playCount == 1)
        #expect(controller.lastPlayCountIn == true)
    }

    @Test func `toggle playback with precount disabled plays without count-in`() async {
        let controller = FakePlaybackController()
        let session = Self.session(controller: controller)
        session.isPrecountEnabled = { false }

        await session.togglePlayback()

        #expect(controller.playCount == 1)
        #expect(controller.lastPlayCountIn == false)
    }
}
