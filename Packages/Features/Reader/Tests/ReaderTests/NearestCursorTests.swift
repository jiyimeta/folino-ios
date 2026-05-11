import CoreGraphics
import Foundation
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

struct NearestCursorTests {
    private static let sp: CGFloat = 14.0 / 4 // staffSize 14 → sp 3.5

    private static func chord(noteID: NoteID, originY: CGFloat) -> LayoutElement {
        .chord(
            notes: [
                LayoutChordNote(
                    noteID: noteID, step: 0, accidental: nil,
                    origin: CGPoint(x: 20, y: originY),
                    tieForward: nil, tieBack: nil, hasGlissando: false,
                ),
            ],
            duration: .quarter,
            stem: .up,
            stemOrigin: CGPoint(x: 20, y: originY),
            hasArpeggio: false, arpeggioRawType: nil,
            isBeamed: false, voiceIndex: 0,
        )
    }

    private static func rest(restID: RestID, originY: CGFloat) -> LayoutElement {
        .rest(
            duration: .quarter,
            origin: CGPoint(x: 60, y: originY),
            voiceIndex: 0, restID: restID, hasLegerLine: false,
        )
    }

    /// System 0: two staves at y-origins 0 and 40. Each staff carries
    /// one chord (x=20) and one rest (x=60) at its centerline.
    private static func makeSystem0(sp: CGFloat) -> LayoutSystem {
        let sTop = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let sBot = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let nTop = NoteID(staff: sTop, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
        let rTop = RestID(staff: sTop, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let nBot = NoteID(staff: sBot, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
        let rBot = RestID(staff: sBot, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let measure = LayoutMeasure(
            measureIndex: 0, origin: .zero, width: 100,
            elements: [
                chord(noteID: nTop, originY: 2 * sp),
                rest(restID: rTop, originY: 2 * sp),
                chord(noteID: nBot, originY: 40 + 2 * sp),
                rest(restID: rBot, originY: 40 + 2 * sp),
            ],
        )
        return LayoutSystem(
            origin: CGPoint(x: 0, y: 0),
            size: CGSize(width: 100, height: 60),
            measures: [measure],
            staffOrigins: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 40)],
            staffAddresses: [sTop, sBot],
            partLabels: [], spanners: [], sp: sp,
        )
    }

    /// System 1: 200 pt below system 0; one staff with the same x layout.
    private static func makeSystem1(sp: CGFloat) -> LayoutSystem {
        let sTop = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let nTop = NoteID(staff: sTop, measureIndex: 1, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
        let rTop = RestID(staff: sTop, measureIndex: 1, voiceIndex: 0, elementIndex: 1)
        let measure = LayoutMeasure(
            measureIndex: 1, origin: .zero, width: 100,
            elements: [
                chord(noteID: nTop, originY: 2 * sp),
                rest(restID: rTop, originY: 2 * sp),
            ],
        )
        return LayoutSystem(
            origin: CGPoint(x: 0, y: 200),
            size: CGSize(width: 100, height: 20),
            measures: [measure],
            staffOrigins: [CGPoint(x: 0, y: 0)],
            staffAddresses: [sTop],
            partLabels: [], spanners: [], sp: sp,
        )
    }

    /// Two-system fixture used by every hit-test case below.
    private static func makeDocument() -> LayoutDocument {
        let metrics = StaffMetrics(staffSize: 14)
        return LayoutDocument(
            size: CGSize(width: 100, height: 220),
            systems: [makeSystem0(sp: metrics.sp), makeSystem1(sp: metrics.sp)],
            metrics: metrics,
        )
    }

    @Test func `press on notehead returns that note`() {
        let doc = Self.makeDocument()
        let result = nearestCursor(at: CGPoint(x: 20, y: 2 * Self.sp), in: doc)
        #expect(result == .item(.note(NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
        ))))
    }

    @Test func `press on rest returns that rest`() {
        let doc = Self.makeDocument()
        let result = nearestCursor(at: CGPoint(x: 60, y: 2 * Self.sp), in: doc)
        #expect(result == .item(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        ))))
    }

    @Test func `press in gap between staves picks nearer staff`() {
        let doc = Self.makeDocument()
        // Top staff mid is at 2 sp; bottom mid is at 40 + 2 sp = ~47.
        // Gap mid Y = (2*sp + 40 + 2*sp) / 2 ≈ 23.5; press a hair below
        // that → should snap to bottom staff.
        let probeY = 2 * Self.sp + 40 / 2 + 1
        let result = nearestCursor(at: CGPoint(x: 20, y: probeY), in: doc)
        #expect(result?.staffOfNote == StaffAddress(partIndex: 1, staffIndexInPart: 0))
    }

    @Test func `press above first system snaps to first system first event`() {
        let doc = Self.makeDocument()
        let result = nearestCursor(at: CGPoint(x: 20, y: -50), in: doc)
        #expect(result == .item(.note(NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
        ))))
    }

    @Test func `press in empty measure returns nil`() {
        // Build a one-system document whose only measure has no elements.
        let metrics = StaffMetrics(staffSize: 14)
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let measure = LayoutMeasure(
            measureIndex: 0, origin: .zero, width: 100, elements: [],
        )
        let system = LayoutSystem(
            origin: .zero,
            size: CGSize(width: 100, height: 20),
            measures: [measure],
            staffOrigins: [.zero],
            staffAddresses: [staff],
            partLabels: [],
            spanners: [],
            sp: metrics.sp,
        )
        let doc = LayoutDocument(
            size: CGSize(width: 100, height: 20),
            systems: [system], metrics: metrics,
        )
        #expect(nearestCursor(at: CGPoint(x: 20, y: 2 * metrics.sp), in: doc) == nil)
    }
}

extension ScoreCursor {
    /// Helper for asserting on `.item(.note(_))` results — only valid
    /// for the test cases that produce a note cursor.
    fileprivate var staffOfNote: StaffAddress? {
        if case let .item(.note(id)) = self { return id.staff }
        return nil
    }
}
