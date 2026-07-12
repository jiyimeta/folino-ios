import CoreGraphics
import Domain
import PencilKit
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

@Suite("Annotation unknown format")
struct AnnotationUnknownFormatTests {
    private let _install: Void = LayoutTestSupport.installed

    private func doc(staffSize: CGFloat = 28) -> LayoutDocument {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure, measure])
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
        var options = ScoreViewOptions()
        options.staffSize = staffSize
        return LayoutEngine.layout(score: score, options: options, availableWidth: 800)
    }

    @Test func `undecodable drawing is skipped not crashing`() {
        let d = doc()
        let bogus = DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 0,
                tickInMeasure: 0,
                partIndex: 0,
                staffIndexInPart: 0,
                dxSp: 0,
                verticalOffsetSp: 0,
            )),
            encodedDrawing: Data([0x00, 0x99, 0x99, 0x99]),
        )
        // Rendering an undecodable drawing yields an empty PKDrawing (skipped), never a crash.
        let rendered = AnnotationAnchoring.display([bogus], in: d)
        #expect(rendered.strokes.isEmpty)
    }

    @Test func `decode returns nil for unknown format`() {
        #expect(InkStrokePencilKitBridge.decodeStoredDrawing(Data([0x00, 0x99, 0x99, 0x99])) == nil)
    }
}
