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
        _ = try ScorePiPFrameRenderer(score: makeScore(), staffSize: 28)
    }

    @Test func `render frame returns buffer at renderer pixel size`() throws {
        let renderer = try ScorePiPFrameRenderer(score: makeScore(), staffSize: 28)
        let buffer = try #require(renderer.renderFrame(playbackCursor: nil))
        #expect(CVPixelBufferGetWidth(buffer) == Int(renderer.pixelSize.width))
        #expect(CVPixelBufferGetHeight(buffer) == Int(renderer.pixelSize.height))
    }

    @Test func `render frame with cursor also succeeds`() throws {
        let renderer = try ScorePiPFrameRenderer(score: makeScore(), staffSize: 28)
        let cursor: ScoreCursor = .beat(measureIndex: 0, tickInMeasure: 0)
        #expect(renderer.renderFrame(playbackCursor: cursor) != nil)
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
