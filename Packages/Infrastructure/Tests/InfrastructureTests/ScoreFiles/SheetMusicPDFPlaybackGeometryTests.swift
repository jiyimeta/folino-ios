import CoreGraphics
import Domain
@testable import ScoreFiles
import SheetMusicPDF
import Testing

/// Verifies the coordinate bridge between ssm's y-up PDF user space and the Reader's top-left mediaBox space.
struct SheetMusicPDFPlaybackGeometryTests {
    @Test func `page sizes pass straight through`() {
        let inner = PDFScoreGeometry(pageSizes: [
            0: CGSize(width: 600, height: 800),
            1: CGSize(width: 300, height: 400),
        ])
        let adapter = SheetMusicPDFPlaybackGeometry(inner)
        #expect(adapter.pageSizes == [0: CGSize(width: 600, height: 800), 1: CGSize(width: 300, height: 400)])
    }

    @Test func `hit-test flips a top-left tap into ssm's y-up page space`() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let note = NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
        // y-up note box near the top of an 800-pt-tall page (y measured from the bottom).
        let inner = PDFScoreGeometry(
            noteRects: [note: PDFElementRect(pageIndex: 0, rect: CGRect(x: 100, y: 700, width: 12, height: 12))],
            pageSizes: [0: CGSize(width: 600, height: 800)],
        )
        let adapter = SheetMusicPDFPlaybackGeometry(inner)

        // A top-left tap at (106, 94) flips to y-up (106, 800 - 94 = 706), inside the note's (100…112, 700…712) box.
        #expect(adapter.cursor(at: CGPoint(x: 106, y: 94), pageIndex: 0) == .item(.note(note)))
        // A top-left tap far from any element resolves to nothing.
        #expect(adapter.cursor(at: CGPoint(x: 10, y: 10), pageIndex: 0) == nil)
    }
}
