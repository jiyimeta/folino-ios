@testable import Domain
import Foundation
import SheetMusicCore
import Testing

/// The regression this file exists for: ink drawn on the original PDF vanished when the user switched to the parsed
/// score, and did not come back on switching return. The two renditions share one array, and a capture from either
/// surface can only describe its own kind — so committing one verbatim deleted the other, permanently.
struct AnnotationLayersTests {
    private func musical(_ id: String) -> DrawingAnchor {
        DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 0,
                tickInMeasure: 0,
                partIndex: 0,
                staffIndexInPart: 0,
                dxSp: 0,
                verticalOffsetSp: 0,
            )),
            encodedDrawing: Data(id.utf8),
        )
    }

    private func page(_ id: String, pageIndex: Int = 0) -> DrawingAnchor {
        DrawingAnchor(kind: .page(PageAnchor(pageIndex: pageIndex)), encodedDrawing: Data(id.utf8))
    }

    @Test func `an anchor kind reports the rendition it belongs to`() {
        #expect(musical("a").kind.rendition == .score)
        #expect(page("b").kind.rendition == .originalPDF)
    }

    @Test func `capturing the score layer leaves PDF ink untouched`() {
        let existing = [page("pdf-1"), musical("score-1"), page("pdf-2")]
        let merged = AnnotationLayers.replacing(.score, in: existing, with: [musical("score-2")])

        #expect(merged.count == 3)
        #expect(
            AnnotationLayers.strokes(of: .originalPDF, in: merged).map(\.encodedDrawing)
                == [Data("pdf-1".utf8), Data("pdf-2".utf8)],
        )
        #expect(AnnotationLayers.strokes(of: .score, in: merged).map(\.encodedDrawing) == [Data("score-2".utf8)])
    }

    @Test func `capturing the PDF layer leaves score ink untouched`() {
        let existing = [page("pdf-1"), musical("score-1")]
        let merged = AnnotationLayers.replacing(.originalPDF, in: existing, with: [page("pdf-2")])

        #expect(AnnotationLayers.strokes(of: .score, in: merged).map(\.encodedDrawing) == [Data("score-1".utf8)])
        #expect(AnnotationLayers.strokes(of: .originalPDF, in: merged).map(\.encodedDrawing) == [Data("pdf-2".utf8)])
    }

    /// The exact shape of the bug: the score surface has nothing to show for a PDF-only item, so its first capture is
    /// empty. That must erase nothing.
    @Test func `an empty capture from one rendition does not erase the other`() {
        let existing = [page("pdf-1"), page("pdf-2")]
        let merged = AnnotationLayers.replacing(.score, in: existing, with: [])

        #expect(merged.map(\.encodedDrawing) == [Data("pdf-1".utf8), Data("pdf-2".utf8)])
    }

    @Test func `replacing a rendition twice converges`() {
        let existing = [page("pdf-1"), musical("score-1")]
        let once = AnnotationLayers.replacing(.score, in: existing, with: [musical("score-2")])
        let twice = AnnotationLayers.replacing(.score, in: once, with: [musical("score-2")])

        #expect(once.map(\.encodedDrawing) == twice.map(\.encodedDrawing))
    }
}
