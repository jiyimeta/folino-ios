import Foundation
import ReaderAnnotationCore
import Testing

/// The canvas history classifies every change by bytes, whoever caused it — so the strip's undo, a three-finger
/// swipe, a seed echo and a fresh stroke all have to land where they belong.
@Suite("Annotation page history")
struct AnnotationPageHistoryTests {
    private static func bytes(_ tag: UInt8) -> Data {
        Data([tag])
    }

    @Test func `a fresh history has nothing to undo or redo`() {
        let history = AnnotationPageHistory(current: Self.bytes(0))
        #expect(!history.canUndo)
        #expect(!history.canRedo)
        #expect(history.undoTarget == nil)
        #expect(history.redoTarget == nil)
    }

    @Test func `a new change is appended and can then be undone and redone`() {
        var history = AnnotationPageHistory(current: Self.bytes(0))
        #expect(history.record(Self.bytes(1)) == .appended)
        #expect(history.canUndo)
        #expect(history.undoTarget == Self.bytes(0))

        // The canvas is set to the undo target; the echo of that set is what comes back.
        #expect(history.record(Self.bytes(0)) == .undone)
        #expect(!history.canUndo)
        #expect(history.redoTarget == Self.bytes(1))

        #expect(history.record(Self.bytes(1)) == .redone)
        #expect(!history.canRedo)
    }

    @Test func `an echo of the current state changes nothing`() {
        var history = AnnotationPageHistory(current: Self.bytes(0))
        history.record(Self.bytes(1))
        #expect(history.record(Self.bytes(1)) == .unchanged)
        #expect(history.cursor == 1)
        #expect(history.snapshots.count == 2)
    }

    @Test func `a new change after an undo drops the redo branch`() {
        var history = AnnotationPageHistory(current: Self.bytes(0))
        history.record(Self.bytes(1))
        history.record(Self.bytes(2))
        history.record(Self.bytes(1)) // undo
        #expect(history.record(Self.bytes(3)) == .appended)
        #expect(!history.canRedo)
        #expect(history.snapshots == [Self.bytes(0), Self.bytes(1), Self.bytes(3)])
    }

    @Test func `rebasing respells the current state without moving the cursor`() {
        var history = AnnotationPageHistory(current: Self.bytes(0))
        history.record(Self.bytes(1))
        // A reseed on re-entry: same ink, different bytes.
        history.rebase(current: Self.bytes(9))
        #expect(history.cursor == 1)
        #expect(history.record(Self.bytes(9)) == .unchanged)
        #expect(history.undoTarget == Self.bytes(0))
    }

    @Test func `the depth is capped by forgetting the oldest state`() {
        var history = AnnotationPageHistory(current: Self.bytes(0))
        for i in 1 ... UInt8(AnnotationPageHistory.maxDepth + 5) {
            history.record(Self.bytes(i))
        }
        #expect(history.snapshots.count == AnnotationPageHistory.maxDepth)
        #expect(history.cursor == AnnotationPageHistory.maxDepth - 1)
        #expect(history.snapshots.first == Self.bytes(6))
    }
}
