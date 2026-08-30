import CoreGraphics
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import SheetMusicPDF
import Testing

/// The drift guard for `EngravedExportLayout`. It mirrors five lines of `PDFExporter.export`'s body — the option
/// resolution, the `ScoreViewOptions`, the available width, the layout call and the pagination — so that annotation
/// ink can be placed on the pages the exporter is about to produce. If a swift-sheet-music bump changes any of that,
/// these tests fail instead of the export silently stamping ink at the wrong coordinates.
@Suite("EngravedExportLayout")
struct EngravedExportLayoutTests {
    private let _install: Void = LayoutTestSupport.installed

    private static func score(measures: Int) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let bars = (0 ..< measures).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])],
        )
    }

    @MainActor
    private static func exported(_ score: Score, title: String) throws -> CGPDFDocument {
        let data = try PDFExporter.export(score: score, options: EngravedExportLayout.exportOptions(title: title))
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGPDFDocument(provider))
    }

    @Test
    @MainActor
    func `the mirrored pagination matches what the exporter actually produces`() throws {
        let score = Self.score(measures: 240)
        let resolved = EngravedExportLayout.resolve(
            score: score, options: EngravedExportLayout.exportOptions(title: "T"),
        )
        let document = try Self.exported(score, title: "T")
        #expect(resolved.pages.count == document.numberOfPages)
        #expect(resolved.pages.count > 1)
    }

    @Test
    @MainActor
    func `the mirrored page size matches the exported media box`() throws {
        let score = Self.score(measures: 8)
        let resolved = EngravedExportLayout.resolve(
            score: score, options: EngravedExportLayout.exportOptions(title: "T"),
        )
        let page = try #require(try Self.exported(score, title: "T").page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width - resolved.pageSize.width) < 0.5)
        #expect(abs(box.height - resolved.pageSize.height) < 0.5)
    }

    @Test
    @MainActor
    func `page bands are contiguous, ascending and non-empty`() {
        let resolved = EngravedExportLayout.resolve(
            score: Self.score(measures: 240), options: EngravedExportLayout.exportOptions(title: "T"),
        )
        #expect(resolved.pages.count > 1)
        for page in resolved.pages {
            #expect(page.usableHeight > 0)
        }
        for (earlier, later) in zip(resolved.pages, resolved.pages.dropFirst()) {
            // Ascending: the next page never starts before this one.
            #expect(later.startY >= earlier.startY)
            // Non-overlapping: a page's claimed band must not reach into where the next page starts, or
            // `AnnotatedExportPlanner.planEngraved`'s `firstIndex(where:)` would attribute ink from the top of the
            // next page's first system back onto this one. The margin-derived `usableHeight` is only an upper
            // bound (pagination stops a page as soon as one more system would not fit, so real content usually
            // falls short of it) — `EngravedExportLayout.resolve` must clamp it down to the gap to the next page.
            #expect(earlier.startY + earlier.usableHeight <= later.startY + 0.01)
        }
    }

    @Test
    @MainActor
    func `the layout document carries every measure so anchors can resolve`() {
        let resolved = EngravedExportLayout.resolve(
            score: Self.score(measures: 12), options: EngravedExportLayout.exportOptions(title: "T"),
        )
        #expect(!resolved.document.systems.isEmpty)
    }
}
