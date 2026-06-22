import PencilKit
import SwiftUI

/// A1 annotation canvas: a non-scrolling `PKCanvasView` sized to the score document, placed as a child of the Reader's
/// already-transformed `scoreSurface` so it rides the existing scroll/zoom transform (it owns NO scroll/zoom of its
/// own). The host `ScoreScrollHost` owns pan/zoom; this canvas's own scroll gestures are disabled so finger touches
/// reach the host. Pencil draws under `.pencilOnly`; with no Pencil, one finger draws under `.anyInput` and two-finger
/// gestures fall through to the host.
struct AnnotationCanvasView: UIViewRepresentable {
    let documentSize: CGSize
    let drawingData: Data?
    /// True when annotation mode is active — controls tool-picker visibility and hit-testing.
    let isAnnotating: Bool
    /// True when an Apple Pencil is the preferred input (iPad w/ Pencil) → pencil draws, finger navigates.
    let isPencilPreferred: Bool
    /// (drawingData, isEmpty) on every change.
    let onChange: (Data, Bool) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        // The host (ScoreScrollHost) owns scroll/zoom. Disable the canvas's own scroll gestures so finger touches are
        // never swallowed here and instead reach the host's pan/pinch. (Primary arbitration approach; see plan §Manual
        // Verification for the on-device check and fallbacks.)
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.drawingPolicy = isPencilPreferred ? .pencilOnly : .anyInput
        canvas.delegate = context.coordinator
        if let drawingData, let drawing = try? PKDrawing(data: drawingData) {
            canvas.drawing = drawing
            context.coordinator.lastLoadedData = drawingData
        }
        context.coordinator.canvas = canvas
        canvas.frame = CGRect(origin: .zero, size: documentSize)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.frame = CGRect(origin: .zero, size: documentSize)
        canvas.drawingPolicy = isPencilPreferred ? .pencilOnly : .anyInput
        // Seed/replace the drawing only when the persisted blob actually changed (e.g. a score swap loaded new ink),
        // never echo our own in-progress edits back onto the canvas.
        if drawingData != context.coordinator.lastLoadedData {
            context.coordinator.lastLoadedData = drawingData
            let drawing = drawingData.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
                canvas.drawing = drawing
            }
        }
        if isAnnotating {
            context.coordinator.showToolPickerIfPossible()
        } else {
            context.coordinator.hideToolPicker()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.hideToolPicker()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onChange: (Data, Bool) -> Void
        weak var canvas: PKCanvasView?
        var lastLoadedData: Data?
        private var toolPicker: PKToolPicker?

        init(onChange: @escaping (Data, Bool) -> Void) {
            self.onChange = onChange
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let data = canvasView.drawing.dataRepresentation()
            lastLoadedData = data // our own edit is now the source of truth; don't let updateUIView overwrite it
            onChange(data, canvasView.drawing.strokes.isEmpty)
        }

        /// Show the standard tool picker once the canvas is in a window and can become first responder.
        func showToolPickerIfPossible() {
            guard let canvas, canvas.window != nil else { return }
            let picker = toolPicker ?? PKToolPicker()
            toolPicker = picker
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            canvas.becomeFirstResponder()
        }

        func hideToolPicker() {
            guard let canvas else { return }
            toolPicker?.setVisible(false, forFirstResponder: canvas)
            toolPicker?.removeObserver(canvas)
            toolPicker = nil
        }
    }
}
