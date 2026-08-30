import CoreGraphics
@testable import Domain
import Foundation
@testable import ScoreFiles
import SheetMusicCore
import Testing

/// Characterization tests for the premise the annotated-PDF export rests on: `CoreGraphicsPDFRenderer` writes the
/// engraved notation into the PDF as vector content (glyphs and paths), not as a page-sized bitmap. Annotated export
/// stamps a raster ink image on top of these pages, which only stays acceptable while the notation underneath is
/// vector. If swift-sheet-music ever switches to rasterizing, these fail.
@Suite("PDF vector output")
struct PDFVectorOutputTests {
    /// A score long enough to paginate: `measures` whole-note bars on one staff.
    static func multiSystemScore(measures: Int) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let bars = (0 ..< measures).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])],
        )
    }

    /// Names of every resource entry of one kind on a page, e.g. `/Font` or `/XObject`.
    static func resourceNames(of page: CGPDFPage, kind: String) -> [String] {
        guard let dict = page.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return [] }
        var bucket: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, kind, &bucket), let bucket else { return [] }
        final class Box { var names: [String] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(bucket, { key, _, info in
            guard let info else { return true }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().names.append(String(cString: key))
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.names
    }

    @Test
    func `the engraved export embeds fonts rather than rasterizing the page`() async throws {
        let data = try await CoreGraphicsPDFRenderer().renderPDF(
            score: Self.multiSystemScore(measures: 8), title: "Vector probe",
        )
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages >= 1)

        let page = try #require(document.page(at: 1))
        // A rasterized page would carry no fonts at all — every glyph would be pixels.
        #expect(!Self.resourceNames(of: page, kind: "Font").isEmpty)
        // …and it would carry exactly the one image that is the page.
        #expect(Self.resourceNames(of: page, kind: "XObject").isEmpty)
    }

    @Test
    func `a long score paginates into more than one page`() async throws {
        let data = try await CoreGraphicsPDFRenderer().renderPDF(
            score: Self.multiSystemScore(measures: 240), title: "Long",
        )
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages > 1)
    }
}
