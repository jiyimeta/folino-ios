import Domain
import Foundation
@testable import Reader
import Testing

/// Switching between the two renditions of a PDF-derived item must not cost the user their ink. The view model is the
/// choke point every capture goes through, so the guarantee is asserted here rather than through the SwiftUI surfaces.
@MainActor
struct ReaderAnnotationLayerTests {
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

    private func page(_ id: String) -> DrawingAnchor {
        DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data(id.utf8))
    }

    /// The reported bug, end to end at the model level: draw on the PDF, switch to the score (whose canvas has nothing
    /// to show and so captures an empty set), switch back — the PDF ink is still there.
    @Test func `ink drawn on the PDF survives a round trip through the score`() async throws {
        let rig = try PDFReaderTestRig(converted: true)
        let vm = rig.makeViewModel()
        await vm.load()

        vm.annotationDrawingsDidChange(AnnotationLayers.replacing(
            .originalPDF, in: vm.annotationDrawings, with: [page("pdf-1")],
        ))
        vm.setDisplaySource(.score)
        // What the score canvas commits the moment it appears: it can only describe its own layer, and has none.
        vm.annotationDrawingsDidChange(AnnotationLayers.replacing(
            .score, in: vm.annotationDrawings, with: [],
        ))
        vm.setDisplaySource(.originalPDF)

        #expect(
            AnnotationLayers.strokes(of: .originalPDF, in: vm.annotationDrawings).map(\.encodedDrawing)
                == [Data("pdf-1".utf8)],
        )
    }

    @Test func `the two layers coexist and each replaces only its own`() async throws {
        let rig = try PDFReaderTestRig(converted: true)
        let vm = rig.makeViewModel()
        await vm.load()

        vm.annotationDrawingsDidChange(AnnotationLayers.replacing(
            .originalPDF, in: vm.annotationDrawings, with: [page("pdf-1")],
        ))
        vm.annotationDrawingsDidChange(AnnotationLayers.replacing(
            .score, in: vm.annotationDrawings, with: [musical("score-1")],
        ))
        #expect(vm.annotationDrawings.count == 2)

        // Erasing everything on the score side leaves the PDF side alone.
        vm.annotationDrawingsDidChange(AnnotationLayers.replacing(
            .score, in: vm.annotationDrawings, with: [],
        ))
        #expect(vm.annotationDrawings.map(\.encodedDrawing) == [Data("pdf-1".utf8)])
    }
}
