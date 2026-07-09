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
    /// The model projected to the current layout (Task B2 `display(...)`). The controller seeds the canvas with this
    /// whenever it changes — on load and on reflow — guarded against echoing the user's own in-progress ink.
    var displayDrawing: PKDrawing
    /// Emits the canvas's live drawing on every change; the container re-anchors its strokes and persists.
    var onChange: (PKDrawing) -> Void
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
    private var onChange: (PKDrawing) -> Void = { _ in }
    private var lastSeededDrawing = PKDrawing()
    private var toolPicker: PKToolPicker?
    private var state: (() -> AnnotationCanvasState)?
    /// Touch types the host's pan/pinch accept by default — captured at install so we can restore them when annotation
    /// mode turns off (while annotating we restrict them to fingers so the Pencil never scrolls/zooms).
    private var defaultPanTouchTypes: [NSNumber] = []
    private var defaultPinchTouchTypes: [NSNumber] = []
    /// Rightmost inked column (`drawing.bounds.maxX`, in document points) of whatever is currently on the canvas — the
    /// quantity that decides when deep zoom would push committed ink off PencilKit's texture. Cached (refreshed only
    /// when the drawing changes, in `applyDrawing` / `canvasViewDrawingDidChange`) so the per-tick `sync` never pays a
    /// bounds recompute. `0` means "no ink" — no texture clamp needed.
    private var inkRightEdge: CGFloat = 0

    /// Leave headroom under the GPU's hard 16,384px max 2D-texture edge (see the class ROOT-CAUSE NOTE) so we split the
    /// zoom *before* PencilKit starts dropping strokes from the right — internal padding / rounding eats a little of
    /// the nominal budget in practice.
    private static let inkTextureBudget: CGFloat = 15000

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
        applyDrawing(spec.displayDrawing)
        applyToolPicker(visible: spec.isAnnotating)
        sync(scrollOffset: scroll.contentOffset)
    }

    /// Mirror the host's scroll offset + zoom onto PencilKit's own scroll machinery so the ink overlays the score.
    ///
    /// Deep-zoom texture clamp: past a point, `inkRightEdge * zoomScale * screenScale` exceeds the GPU texture budget
    /// and PencilKit clamps its committed-ink render to an origin-anchored sub-rect, dropping strokes from the right
    /// edge first (the "ink disappears when you zoom all the way in" bug). We can't grow that budget, so we cap the
    /// PencilKit `zoomScale` at the texture-safe ceiling and carry the *residual* zoom as a plain view transform on the
    /// viewport-sized canvas — a cheap CALayer bitmap upscale that never clips (it only softens the ink slightly past
    /// the ceiling). Splitting `z = zc * residual` and dividing `residual` back out of `contentOffset` keeps the
    /// on-screen mapping `screen(p) = p * z - target` exactly invariant, so the ink stays pixel-aligned with the score.
    /// Below the ceiling `residual == 1` and this is byte-identical to a plain `zoomScale = z` mirror.
    func sync(scrollOffset: CGPoint) {
        guard let canvas, let state else { return }
        let s = state()
        if canvas.contentSize != s.documentSize { canvas.contentSize = s.documentSize }
        if canvas.contentInset != s.contentInset { canvas.contentInset = s.contentInset }
        let z = max(0.01, s.zoomScale)
        let (zc, residual) = zoomSplit(for: z, canvas: canvas)
        if abs(canvas.zoomScale - zc) > 0.0001 { canvas.zoomScale = zc }
        let target = CGPoint(x: scrollOffset.x + s.contentOffsetBias.x, y: scrollOffset.y + s.contentOffsetBias.y)
        // `contentOffset` lives in the un-residual-scaled space; the residual view transform re-multiplies it back.
        let adjusted = residual == 1
            ? target
            : CGPoint(x: target.x / residual, y: target.y / residual)
        if canvas.contentOffset != adjusted { canvas.contentOffset = adjusted }
        applyResidualTransform(residual, to: canvas)
    }

    /// Split an on-screen zoom `z` into `(zoomScale, residual)`: PencilKit renders committed ink at `zoomScale` (kept
    /// within the texture budget), and the caller scales the canvas view by `residual` for anything beyond it. Returns
    /// `(z, 1)` when the ink comfortably fits — the overwhelmingly common case. The cap is origin-anchored on the
    /// rightmost inked column because PencilKit's clamp is too (a stroke at x drops when `x * zoomScale * screenScale`
    /// crosses the budget), and never exceeds `maximumZoomScale`, past which the `zoomScale` setter silently clamps and
    /// desyncs the mirror.
    private func zoomSplit(for z: CGFloat, canvas: PKCanvasView) -> (zoomScale: CGFloat, residual: CGFloat) {
        guard inkRightEdge > 0 else { return (z, 1) }
        let displayScale = canvas.traitCollection.displayScale
        let screenScale = displayScale > 0 ? displayScale : 2
        let safeZoom = Self.inkTextureBudget / (inkRightEdge * screenScale)
        let cap = min(safeZoom, canvas.maximumZoomScale)
        guard z > cap else { return (z, 1) }
        return (cap, z / cap)
    }

    /// Scale the viewport-sized canvas view about its top-left corner (matching the score's `.topLeading` committed
    /// zoom) so the residual zoom rides a cheap CALayer bitmap upscale instead of PencilKit's texture. Identity when
    /// `residual == 1`. `UIView.transform` pivots about the view's center, so offset the translation to move the pivot
    /// to the top-left corner.
    private func applyResidualTransform(_ residual: CGFloat, to canvas: PKCanvasView) {
        let size = canvas.bounds.size
        let transform: CGAffineTransform = residual == 1 || size.width == 0 || size.height == 0
            ? .identity
            : CGAffineTransform(
                a: residual, b: 0, c: 0, d: residual,
                tx: (residual - 1) * size.width / 2,
                ty: (residual - 1) * size.height / 2,
            )
        if canvas.transform != transform { canvas.transform = transform }
    }

    func teardown() {
        applyToolPicker(visible: false)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        lastSeededDrawing = canvasView.drawing // our own edit is the source of truth; don't let applyDrawing echo it
        inkRightEdge = Self.rightEdge(of: canvasView.drawing)
        onChange(canvasView.drawing)
    }

    /// Seed/replace the canvas only when the projected model actually changed (load or reflow); never echo the user's
    /// own in-progress edits back onto the canvas.
    private func applyDrawing(_ drawing: PKDrawing) {
        guard let canvas else { return }
        if drawing.dataRepresentation() != lastSeededDrawing.dataRepresentation() {
            lastSeededDrawing = drawing
            inkRightEdge = Self.rightEdge(of: drawing)
            if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
                canvas.drawing = drawing
            }
        }
    }

    /// Rightmost inked column in document points, or `0` when there is no ink — `PKDrawing.bounds` is `.null` for an
    /// empty drawing (its `maxX` is not meaningful), so guard on the stroke count.
    private static func rightEdge(of drawing: PKDrawing) -> CGFloat {
        guard !drawing.strokes.isEmpty else { return 0 }
        let maxX = drawing.bounds.maxX
        return maxX.isFinite ? max(0, maxX) : 0
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
