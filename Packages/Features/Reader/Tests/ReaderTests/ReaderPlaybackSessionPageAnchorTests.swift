import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderPlaybackSessionPageAnchorTests {
    private static func twoMeasureScore() -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [Measure(voices: []), Measure(voices: [])])],
        )
        return Score(
            division: 480,
            parts: [part],
            systemMeasures: [SystemMeasure(), SystemMeasure()],
            metaTags: [:],
        )
    }

    private static func playingSession(
        _ controller: FakePlaybackController, at cursor: ScoreCursor,
    ) -> ReaderPlaybackSession {
        let score = twoMeasureScore()
        let session = ReaderPlaybackSession(controller: controller, museScoreGeneralProvider: nil)
        session.scoreProvider = { score }
        session.startObservingCursor()
        controller.emitIsPlaying(true)
        controller.emitCursor(cursor)
        return session
    }

    @Test func `page anchor leads the live cursor by one beat while playing`() {
        let controller = FakePlaybackController()
        let session = Self.playingSession(controller, at: .beat(measureIndex: 0, tickInMeasure: 0))
        // 1 beat = 480 ticks into a 1920-tick 4/4 measure.
        #expect(session.pageAnchorCursor == .beat(measureIndex: 0, tickInMeasure: 480))
    }

    @Test func `page anchor is nil when not playing`() {
        let controller = FakePlaybackController()
        let session = Self.playingSession(controller, at: .beat(measureIndex: 0, tickInMeasure: 0))
        controller.emitIsPlaying(false)
        #expect(session.pageAnchorCursor == nil)
    }

    @Test func `page anchor is nil while scrubbing`() {
        let controller = FakePlaybackController()
        let session = Self.playingSession(controller, at: .beat(measureIndex: 0, tickInMeasure: 0))
        session.beginScrub()
        #expect(session.pageAnchorCursor == nil)
    }
}
