import PencilKit
import Testing
import UIKit

/// Pins of the PencilKit behaviour the annotation undo design rests on (see `AnnotationCanvasSession`). Not tests of
/// our code — of the framework's — so a change in an OS release shows up here rather than as a user report.
///
/// Measured 2026-09-03 on the iOS 26.5 simulator: `PKCanvasView.undoManager` is the responder chain's (the window's
/// by default), a programmatic `drawing` set neither clears it nor pushes an action onto it, and resigning first
/// responder leaves it alone. `PKDrawing.dataRepresentation()` is NOT byte-stable across a round trip, which is why
/// the history is not kept as snapshots.
@MainActor
@Suite("PencilKit undo probes")
struct PencilKitUndoProbeTests {
    private final class ProbeCanvas: PKCanvasView {
        var pageUndoManager: UndoManager?
        override var undoManager: UndoManager? {
            pageUndoManager ?? super.undoManager
        }
    }

    private static func stroke(x: CGFloat) -> PKStroke {
        let points = (0 ..< 5).map { i in
            PKStrokePoint(
                location: CGPoint(x: x + CGFloat(i) * 10, y: 100), timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2,
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    @Test func `dataRepresentation is not byte-stable across a round trip`() throws {
        let drawing = PKDrawing(strokes: [Self.stroke(x: 10), Self.stroke(x: 200)])
        let a = drawing.dataRepresentation()
        #expect(a == drawing.dataRepresentation(), "two calls on the same drawing disagree")
        let roundTripped = try PKDrawing(data: a).dataRepresentation()
        #expect(a != roundTripped, "a round trip is byte-stable now — snapshots could carry the history after all")
    }

    @Test func `the canvas uses the responder chain's undo manager and a programmatic set leaves it alone`() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let canvas = ProbeCanvas(frame: window.bounds)
        window.addSubview(canvas)
        window.makeKeyAndVisible()
        _ = canvas.becomeFirstResponder()
        #expect(canvas.undoManager === window.undoManager)

        // An override is honoured — the hook the per-page managers hang off.
        let pageManager = UndoManager()
        canvas.pageUndoManager = pageManager
        #expect(canvas.undoManager === pageManager)

        // A dummy action, so we can see both whether a programmatic set wipes the stack and whether it pushes one.
        var dummyFired = false
        pageManager.registerUndo(withTarget: window) { _ in dummyFired = true }
        canvas.drawing = PKDrawing(strokes: [Self.stroke(x: 10)])
        canvas.drawing = PKDrawing()
        _ = canvas.resignFirstResponder()
        #expect(pageManager.canUndo, "a programmatic set cleared the undo stack")
        pageManager.undo()
        #expect(dummyFired, "a programmatic set pushed its own undo action ahead of the user's")
        #expect(!pageManager.canUndo)
    }
}
