import PencilKit
import SwiftUI
import UIKit

/// Read-at-call-time geometry the annotation canvas mirrors onto PencilKit's own scroll machinery (so the ink
/// registers with the score). Recomputed on every scroll/pinch tick — no SwiftUI render round-trip, so the ink tracks
/// without lag.
struct AnnotationCanvasState {
    var documentSize: CGSize
    /// Effective on-screen zoom: `viewportZoom * fitToWidth * live-pinch magnification`.
    var zoomScale: CGFloat
    /// The non-scroll part of the canvas contentOffset (padding + live-pinch anchor + horizontal pinch offset). The
    /// controller adds the scroll view's ACTUAL `contentOffset` — using the real UIScrollView offset rather than the
    /// published `liveScrollOffset` @State, which lags during a programmatic pinch-commit scroll and would otherwise
    /// leave the ink badly offset after a zoom commit.
    var contentOffsetBias: CGPoint
    var contentInset: UIEdgeInsets
}

/// Opt-in annotation overlay config passed to `ScoreScrollHost`. When present, the host installs a viewport-sized
/// `PKCanvasView` as a SUBVIEW of its scroll view (pinned to the `frameLayoutGuide` — the visible viewport, NOT the
/// content). Because the scroll view's pan + custom pinch are then ancestors of the canvas, they receive finger
/// touches by the normal UIKit responder contract (no fragile per-touch hit-testing across a SwiftUI ZStack), while
/// `.pencilOnly` keeps the Pencil drawing. The canvas stays viewport-sized (texture-safe); PencilKit holds the tall
/// document in its own contentSize/zoomScale/contentOffset, mirrored from `state`.
struct AnnotationOverlaySpec {
    var isAnnotating: Bool
    var isPencilPreferred: Bool
    var drawingData: Data?
    var onChange: (Data, Bool) -> Void
    var state: () -> AnnotationCanvasState
}

/// Owns the annotation `PKCanvasView`: installs it as a viewport-pinned subview of the host scroll view, mirrors the
/// host's scroll/zoom onto PencilKit's own scroll machinery, forwards drawing changes, and manages the tool picker.
/// Created and retained by `ScoreScrollHost`'s Coordinator.
///
/// ROOT-CAUSE NOTE (why the canvas is viewport-sized, not document-sized): a `PKCanvasView` whose bounds height equals
/// the full score height (~8421pt) overflows PencilKit's live-stroke render surface — `bounds.height × screenScale`
/// exceeds the GPU's 16,384px max 2D texture — so the in-progress stroke renders scaled-up from the top-leading
/// origin (committed ink stays correct, so it snaps back on lift). Sizing the canvas to the viewport keeps the live
/// surface small; the tall document lives in PencilKit's own scroll/zoom.
@MainActor
final class AnnotationCanvasController: NSObject, PKCanvasViewDelegate {
    private weak var canvas: PKCanvasView?
    private var onChange: (Data, Bool) -> Void = { _, _ in }
    private var lastLoadedData: Data?
    private var toolPicker: PKToolPicker?
    private var state: (() -> AnnotationCanvasState)?
    /// Touch types the host's pan/pinch accept by default — captured at install so we can restore them when annotation
    /// mode turns off (while annotating we restrict them to fingers so the Pencil never scrolls/zooms).
    private var defaultPanTouchTypes: [NSNumber] = []
    private var defaultPinchTouchTypes: [NSNumber] = []

    /// Install the canvas once, as a viewport-pinned subview of the scroll view (pinned to `frameLayoutGuide`).
    func install(in scroll: UIScrollView, pinch: UIPinchGestureRecognizer?, spec: AnnotationOverlaySpec) {
        guard canvas == nil else { return }
        onChange = spec.onChange
        defaultPanTouchTypes = scroll.panGestureRecognizer.allowedTouchTypes
        defaultPinchTouchTypes = pinch?.allowedTouchTypes ?? []
        let view = PKCanvasView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.isOpaque = false
        view.contentInsetAdjustmentBehavior = .never
        view.bouncesZoom = false
        view.bounces = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        // PencilKit holds the tall document in its OWN scroll machinery; the canvas view stays viewport-sized.
        view.isScrollEnabled = true
        view.minimumZoomScale = 0.01
        view.maximumZoomScale = 100
        view.panGestureRecognizer.isEnabled = false
        view.pinchGestureRecognizer?.isEnabled = false
        view.delegate = self
        canvas = view
        // SUBVIEW of the scroll view, pinned to the VISIBLE viewport (frameLayoutGuide, NOT the content) — so the
        // canvas is viewport-sized + fixed in the viewport while the score scrolls, and the scroll view's pan +
        // custom pinch (ancestors) receive finger touches that land on it (the reliable UIKit responder contract).
        scroll.addSubview(view)
        let guide = scroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            view.topAnchor.constraint(equalTo: guide.topAnchor),
            view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
    }

    /// Reflect the current spec onto the canvas every SwiftUI update (mode, drawing, tool picker, touch policy).
    func update(spec: AnnotationOverlaySpec, scroll: UIScrollView, pinch: UIPinchGestureRecognizer?) {
        guard let canvas else { return }
        onChange = spec.onChange
        state = spec.state
        // Re-assert each cycle: .pencilOnly re-enables the canvas's own pan.
        canvas.drawingPolicy = spec.isPencilPreferred ? .pencilOnly : .anyInput
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        // While annotating, only fingers drive the host's scroll/zoom — the Pencil (hovering OR contacting) must never
        // scroll/zoom; it draws. Restore the captured defaults when annotation mode is off.
        let fingerOnly: [NSNumber] = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.panGestureRecognizer.allowedTouchTypes = spec.isAnnotating ? fingerOnly : defaultPanTouchTypes
        pinch?.allowedTouchTypes = spec.isAnnotating ? fingerOnly : defaultPinchTouchTypes
        // Touch handling on only while annotating: then .pencilOnly draws the Pencil and fingers fall through to the
        // scroll view's recognizers. Off → the canvas is transparent to touches (committed ink still displays).
        canvas.isUserInteractionEnabled = spec.isAnnotating
        applyDrawing(spec.drawingData)
        applyToolPicker(visible: spec.isAnnotating)
        sync(scrollOffset: scroll.contentOffset)
    }

    /// Mirror the host's scroll offset + zoom onto PencilKit's own scroll machinery so the ink overlays the score.
    func sync(scrollOffset: CGPoint) {
        guard let canvas, let state else { return }
        let s = state()
        if canvas.contentSize != s.documentSize { canvas.contentSize = s.documentSize }
        if canvas.contentInset != s.contentInset { canvas.contentInset = s.contentInset }
        let z = max(0.01, s.zoomScale)
        if abs(canvas.zoomScale - z) > 0.0001 { canvas.zoomScale = z }
        let target = CGPoint(x: scrollOffset.x + s.contentOffsetBias.x, y: scrollOffset.y + s.contentOffsetBias.y)
        if canvas.contentOffset != target { canvas.contentOffset = target }
    }

    func teardown() {
        applyToolPicker(visible: false)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let data = canvasView.drawing.dataRepresentation()
        lastLoadedData = data // our own edit is now the source of truth; don't let applyDrawing overwrite it
        onChange(data, canvasView.drawing.strokes.isEmpty)
    }

    /// Seed/replace the drawing only when the persisted blob actually changed (e.g. a score swap loaded new ink),
    /// never echo our own in-progress edits back onto the canvas.
    private func applyDrawing(_ drawingData: Data?) {
        guard let canvas else { return }
        if drawingData != lastLoadedData {
            lastLoadedData = drawingData
            let drawing = drawingData.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
                canvas.drawing = drawing
            }
        }
    }

    private func applyToolPicker(visible: Bool) {
        guard let canvas else { return }
        if visible {
            guard canvas.window != nil else { return }
            let picker = toolPicker ?? PKToolPicker()
            toolPicker = picker
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            canvas.becomeFirstResponder()
        } else {
            toolPicker?.setVisible(false, forFirstResponder: canvas)
            toolPicker?.removeObserver(canvas)
            toolPicker = nil
        }
    }
}
