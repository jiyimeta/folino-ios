import CoreVideo
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

extension Instrument {
    fileprivate static var empty: Instrument {
        Instrument(id: "")
    }
}

@MainActor
struct ScorePiPFrameRendererTests {
    init() {
        _ = LayoutTestSupport.installed
    }

    @Test func `init succeeds for valid score`() throws {
        _ = try ScorePiPFrameRenderer(
            score: makeScore(), staffSize: 28,
            collapseMultiMeasureRests: false, showInvisibleElements: false,
        )
    }

    @Test func `render frame returns buffer at renderer pixel size`() throws {
        let renderer = try ScorePiPFrameRenderer(
            score: makeScore(), staffSize: 28,
            collapseMultiMeasureRests: false, showInvisibleElements: false,
        )
        let buffer = try #require(renderer.renderFrame(playbackCursor: nil))
        #expect(CVPixelBufferGetWidth(buffer) == Int(renderer.pixelSize.width))
        #expect(CVPixelBufferGetHeight(buffer) == Int(renderer.pixelSize.height))
    }

    @Test func `render frame with cursor also succeeds`() throws {
        let renderer = try ScorePiPFrameRenderer(
            score: makeScore(), staffSize: 28,
            collapseMultiMeasureRests: false, showInvisibleElements: false,
        )
        let cursor: ScoreCursor = .beat(measureIndex: 0, tickInMeasure: 0)
        #expect(renderer.renderFrame(playbackCursor: cursor) != nil)
    }

    /// Minimal Score with one part / one staff / one measure containing a quarter-note chord so the layout engine
    /// produces at least one system. A staff with no measures causes `LayoutEngine` to emit zero systems, which makes
    /// `ScorePiPFrameRenderer.prepare` throw "Layout produced no systems".
    private func makeScore() -> Score {
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )),
        ])
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            measures: [Measure(voices: [voice])],
        )
        let part = Part(
            id: "P0", trackName: "Test", instrument: .empty,
            staves: [staff],
        )
        return Score(division: 480, parts: [part], metaTags: [:])
    }
}
