import Domain
import Foundation
@testable import Reader
import ReaderAnnotationCore
import Testing
import UtilityCore

/// The three ways out of an annotation session, at the view-model seam: ✓ keeps, ✕ restores the ink the session
/// began with, and clear-all empties the layer — each of them leaving annotation mode and telling the containers to
/// redraw through the reseed ticket.
@MainActor
@Suite(.serialized)
struct AnnotationSessionTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "t.mid", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func makeVM() -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: makeItem(),
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(fileURLWithPath: "/dev/null"),
        )
    }

    private static func anchor() -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
    }

    private static func strokes(_ count: Int, tag: UInt8 = 0) -> [DrawingAnchor] {
        (0 ..< count).map {
            DrawingAnchor(kind: .musical(anchor()), encodedDrawing: Data([tag, UInt8($0 & 0xFF)]))
        }
    }

    @Test func `the end mode follows the canvas's changes and the layer's ink`() {
        let vm = Self.makeVM()
        vm.beginAnnotationSession()
        #expect(vm.annotationSessionEndMode == .commitUnchanged)

        vm.annotationDrawings = Self.strokes(2)
        #expect(vm.annotationSessionEndMode == .clearAll)

        vm.annotationCanvasSession.hasChanges = true
        #expect(vm.annotationSessionEndMode == .commitEdited)
    }

    @Test func `finishing keeps the session's ink and leaves the reseed ticket alone`() {
        let vm = Self.makeVM()
        let before = Self.strokes(1)
        vm.annotationDrawings = before
        vm.beginAnnotationSession()
        let drawn = Self.strokes(3, tag: 1)
        vm.annotationDrawingsDidChange(drawn)
        vm.annotationCanvasSession.hasChanges = true
        let ticket = vm.annotationReseedTicket

        vm.finishAnnotationSession()

        #expect(!vm.isAnnotating)
        #expect(vm.annotationDrawings == drawn)
        #expect(vm.annotationReseedTicket == ticket)
    }

    @Test func `discarding restores the ink the session began with and asks for a redraw`() {
        let vm = Self.makeVM()
        let before = Self.strokes(1)
        vm.annotationDrawings = before
        vm.beginAnnotationSession()
        vm.annotationDrawingsDidChange(Self.strokes(3, tag: 1))
        vm.annotationCanvasSession.hasChanges = true
        let ticket = vm.annotationReseedTicket

        vm.discardAnnotationSession()

        #expect(!vm.isAnnotating)
        #expect(vm.annotationDrawings == before)
        #expect(vm.annotationReseedTicket == ticket + 1)
    }

    @Test func `discarding a session that changed nothing leaves the layer untouched`() {
        let vm = Self.makeVM()
        vm.annotationDrawings = Self.strokes(2)
        vm.beginAnnotationSession()
        // A capture with no user change behind it — a reflow's re-anchoring, say — must not be mistaken for one.
        let recaptured = Self.strokes(2, tag: 1)
        vm.annotationDrawingsDidChange(recaptured)
        let ticket = vm.annotationReseedTicket

        vm.discardAnnotationSession()

        #expect(!vm.isAnnotating)
        #expect(vm.annotationDrawings == recaptured)
        #expect(vm.annotationReseedTicket == ticket)
    }

    @Test func `clearing empties the layer and asks for a redraw`() {
        let vm = Self.makeVM()
        vm.annotationDrawings = Self.strokes(2)
        vm.beginAnnotationSession()
        let ticket = vm.annotationReseedTicket

        vm.clearAllAnnotations()

        #expect(!vm.isAnnotating)
        #expect(vm.annotationDrawings.isEmpty)
        #expect(vm.annotationReseedTicket == ticket + 1)
    }

    @Test func `entering a session starts with no changes but keeps the undo history`() {
        let vm = Self.makeVM()
        vm.annotationCanvasSession.hasChanges = true
        vm.annotationCanvasSession.canUndo = true

        vm.beginAnnotationSession()

        #expect(!vm.annotationCanvasSession.hasChanges)
        // Undo outlives the session, as the editing session's does: leaving and coming back has to leave it where
        // it was.
        #expect(vm.annotationCanvasSession.canUndo)
    }

    @Test func `discarding and clearing end the undo history, finishing keeps it`() {
        let vm = Self.makeVM()
        vm.annotationDrawings = Self.strokes(1)
        let manager = vm.annotationCanvasSession.undoManager(for: 0)
        let target = NSObject()
        manager.registerUndo(withTarget: target) { _ in }
        vm.beginAnnotationSession()
        vm.annotationCanvasSession.canUndo = true
        vm.finishAnnotationSession()
        #expect(manager.canUndo)
        #expect(vm.annotationCanvasSession.canUndo)
        // The same page gets the same manager back — that is what carries the history across sessions.
        #expect(vm.annotationCanvasSession.undoManager(for: 0) === manager)

        vm.beginAnnotationSession()
        vm.annotationCanvasSession.hasChanges = true
        vm.discardAnnotationSession()
        #expect(!manager.canUndo)
        #expect(!vm.annotationCanvasSession.canUndo)

        manager.registerUndo(withTarget: target) { _ in }
        vm.beginAnnotationSession()
        vm.clearAllAnnotations()
        #expect(!manager.canUndo)
    }
}
