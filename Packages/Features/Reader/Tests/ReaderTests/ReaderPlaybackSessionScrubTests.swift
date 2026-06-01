import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderPlaybackSessionScrubTests {
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

    private static func session(
        controller: FakePlaybackController? = FakePlaybackController(),
    ) -> ReaderPlaybackSession {
        let score = twoMeasureScore()
        let session = ReaderPlaybackSession(controller: controller, museScoreGeneralProvider: nil)
        session.scoreProvider = { score }
        return session
    }

    @Test func `display cursor falls back to playback cursor when not scrubbing`() {
        let session = Self.session()
        session.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        #expect(session.scrubCursor == nil)
        #expect(session.displayCursor == .beat(measureIndex: 1, tickInMeasure: 0))
    }

    @Test func `begin scrub seeds the provisional cursor from the real cursor`() {
        let session = Self.session()
        session.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        session.beginScrub()
        #expect(session.scrubCursor == .beat(measureIndex: 1, tickInMeasure: 0))
    }

    @Test func `update scrub moves the provisional cursor without touching the real one`() {
        let session = Self.session()
        session.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))
        session.beginScrub()
        session.updateScrub(toFraction: 0.5) // half of a 4s timeline = 2s = measure 1 start
        #expect(session.scrubCursor == .beat(measureIndex: 1, tickInMeasure: 0))
        #expect(session.displayCursor == .beat(measureIndex: 1, tickInMeasure: 0))
        #expect(session.playbackCursor == .beat(measureIndex: 0, tickInMeasure: 0))
    }

    @Test func `end scrub commits to the controller and clears scrub state`() async {
        let controller = FakePlaybackController()
        let session = Self.session(controller: controller)
        session.beginScrub()
        session.updateScrub(toFraction: 0.5)
        session.endScrub()
        #expect(session.scrubCursor == nil)
        #expect(session.playbackCursor == .beat(measureIndex: 1, tickInMeasure: 0))
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.recordedSetCursorCalls == [.beat(measureIndex: 1, tickInMeasure: 0)])
    }

    @Test func `end scrub without a controller still updates the local cursor`() {
        let session = Self.session(controller: nil)
        session.beginScrub()
        session.updateScrub(toFraction: 1.0)
        session.endScrub()
        #expect(session.scrubCursor == nil)
        #expect(session.playbackCursor == .beat(measureIndex: 1, tickInMeasure: 1920))
    }
}
