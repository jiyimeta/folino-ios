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
    @Test func `init succeeds for valid score`() throws {
        _ = try ScorePiPFrameRenderer(
            score: makeScore(),
            staffSize: 14,
            pixelSize: CGSize(width: 600, height: 200),
        )
    }

    @Test func `render frame returns buffer of requested size`() throws {
        let renderer = try ScorePiPFrameRenderer(
            score: makeScore(),
            staffSize: 14,
            pixelSize: CGSize(width: 600, height: 200),
        )
        let buffer = try #require(renderer.renderFrame(playbackCursor: nil))
        #expect(CVPixelBufferGetWidth(buffer) == 600)
        #expect(CVPixelBufferGetHeight(buffer) == 200)
    }

    @Test func `render frame with cursor also succeeds`() throws {
        let renderer = try ScorePiPFrameRenderer(
            score: makeScore(),
            staffSize: 14,
            pixelSize: CGSize(width: 600, height: 200),
        )
        let cursor: ScoreCursor = .beat(measureIndex: 0, tickInMeasure: 0)
        let buffer = try #require(renderer.renderFrame(playbackCursor: cursor))
        #expect(CVPixelBufferGetWidth(buffer) == 600)
    }

    /// Minimal Score with one part / one staff / one measure.
    /// Modeled after the `makeScore()` helper in `ScoreFilteringTests.swift`.
    private func makeScore() -> Score {
        let part = Part(
            id: "P0", trackName: "Test", instrument: .empty,
            staves: [Staff(staffType: "stdNormal", group: "pitched")],
        )
        return Score(division: 480, parts: [part], metaTags: [:])
    }
}
