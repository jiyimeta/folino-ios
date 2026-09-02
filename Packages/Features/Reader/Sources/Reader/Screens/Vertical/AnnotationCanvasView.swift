// PARITY(macos): live annotation input — macOS ships no `PKCanvasView` and no `PKToolPicker`, so this overlay has
//   nothing to port onto: Ⅴ owes the Mac an ink surface of its own, plus a tool picker, plus a way to register it
//   with an `NSScrollView` the way `ScoreScrollHost` registers this one. Committed ink already displays on the Mac
//   (`MacScoreInkOverlay`); it is only authoring that is missing.

#if os(iOS)
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

/// A stable, view-identity-independent handle the paged containers use to imperatively reseed the live annotation
/// canvas at a page-turn commit — synchronously, in the commit callout, BEFORE any queued PencilKit `didChange`
/// echo of the just-left page can run. The reactive spec path (`displayDrawing`) can't win that race: its byte
/// guard is only armed at the next render, after the echo. Held as `@State` by the container; the controller links
/// itself in on install/update.
@MainActor
final class AnnotationCanvasHandle {
    fileprivate weak var controller: AnnotationCanvasController?

    /// Force the live canvas to `drawing` for the new page and suppress echo capture until the user next draws.
    func reseedForPageTurn(_ drawing: PKDrawing) {
        controller?.reseedForPageTurn(drawing)
    }
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
    /// Where the controller reports undo / redo availability and whether the session changed the ink — read by the
    /// strip's annotation controls. `nil` (the default) for previews and hosts with no strip to report to.
    var canvasSession: AnnotationCanvasSession?
    /// The model projected to the current layout (Task B2 `display(...)`). The controller seeds the canvas with this
    /// whenever it changes — on load and on reflow — guarded against echoing the user's own in-progress ink.
    var displayDrawing: PKDrawing
    /// Emits the canvas's live drawing on every change; the container re-anchors its strokes and persists.
    var onChange: (PKDrawing) -> Void
    var state: () -> AnnotationCanvasState
    /// Stable handle the container uses to imperatively reseed the canvas at a page-turn commit (see
    /// `AnnotationCanvasHandle`). The controller links itself into this on install/update.
    var handle: AnnotationCanvasHandle
    /// True while note editing is active (spec §5.9): existing ink dims to a translucent reference layer and stops
    /// accepting touches, so the editing overlay reads as the foreground without the user losing sight of prior
    /// annotations.
    var isInkDimmed = false
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
    /// Internal rather than private, along with the four session-tracking properties below, so the session half of
    /// this controller (`AnnotationCanvasController+Session.swift`) can reach them from its own file.
    weak var canvas: PKCanvasView?
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
    /// After a page-turn reseed, PencilKit `didChange` deliveries (the programmatic reseed's own echo, and any late
    /// wet-to-dry echo of the page we just left) are NOT user edits — swallow them until the user puts a tool down
    /// on the new page. Otherwise the echo clobbers `projectedAnnotations` back to the old ink and/or mis-anchors it
    /// to the new page. Armed by `reseedForPageTurn`, cleared by the tool lifecycle.
    private var ignoreEchoesUntilUserDraws = false
    /// The strip's view of the session — see `AnnotationCanvasSession`. Replaced on every `update`, so the object the
    /// current view model owns is always the one written to.
    var canvasSession: AnnotationCanvasSession?
    /// The drawing bytes the current session started from on the CURRENT page — `nil` outside a session. What the
    /// canvas holds is compared against this after every change to answer "has the session changed anything?";
    /// undoing back to it reads as unchanged again. Carried forward by a programmatic reseed (a reflow) while nothing
    /// has changed, so a re-projection of the same ink is not mistaken for an edit.
    var sessionSeedBytes: Data?
    /// Latched at a page turn if the page being left differed from its seed: a change on an earlier page is still a
    /// change, even though that page's undo stack is gone.
    var changedOnEarlierPages = false
    /// The undo manager's own notifications, observed for the session's duration so undo / redo availability is
    /// republished on every checkpoint — a three-finger swipe never passes through this controller's own methods.
    var undoObservers: [any NSObjectProtocol] = []

    /// Leave headroom under the GPU's hard 16,384px max 2D-texture edge (see the class ROOT-CAUSE NOTE) so we split the
    /// zoom *before* PencilKit starts dropping strokes from the right — internal padding / rounding eats a little of
    /// the nominal budget in practice.
    private static let inkTextureBudget: CGFloat = 15000

    /// Install the canvas once, as a viewport-pinned subview of the scroll view (pinned to `frameLayoutGuide`).
    func install(in scroll: UIScrollView, pinch: UIPinchGestureRecognizer?, spec: AnnotationOverlaySpec) {
        guard canvas == nil else { return }
        onChange = spec.onChange
        spec.handle.controller = self
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
        spec.handle.controller = self
        canvasSession = spec.canvasSession
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
        // While note editing is active, the ink is a dimmed reference layer only — never interactive, regardless of
        // `isAnnotating` (the annotation toggle is hidden during editing, but this guards belt-and-suspenders).
        canvas.isUserInteractionEnabled = !spec.isInkDimmed && spec.isAnnotating
        canvas.alpha = spec.isInkDimmed ? 0.4 : 1.0
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
        if canvas.contentSize != s.documentSize {
            canvas.contentSize = s.documentSize
        }
        if canvas.contentInset != s.contentInset {
            canvas.contentInset = s.contentInset
        }
        let z = max(0.01, s.zoomScale)
        let (zc, residual) = zoomSplit(for: z, canvas: canvas)
        if abs(canvas.zoomScale - zc) > 0.0001 {
            canvas.zoomScale = zc
        }
        let target = CGPoint(x: scrollOffset.x + s.contentOffsetBias.x, y: scrollOffset.y + s.contentOffsetBias.y)
        // `contentOffset` lives in the un-residual-scaled space; the residual view transform re-multiplies it back.
        let adjusted = residual == 1
            ? target
            : CGPoint(x: target.x / residual, y: target.y / residual)
        if canvas.contentOffset != adjusted {
            canvas.contentOffset = adjusted
        }
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
        if canvas.transform != transform {
            canvas.transform = transform
        }
    }

    func teardown() {
        applyToolPicker(visible: false)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        lastSeededDrawing = canvasView.drawing // our own edit is the source of truth; don't let applyDrawing echo it
        inkRightEdge = Self.rightEdge(of: canvasView.drawing)
        publishSessionState()
        // After a page-turn reseed, swallow echoes until the user actually puts a tool down on the new page — see
        // `ignoreEchoesUntilUserDraws`. The next genuine stroke re-enables capture and recaptures the whole canvas.
        guard !ignoreEchoesUntilUserDraws else { return }
        onChange(canvasView.drawing)
    }

    /// A genuine user edit is starting on the current page — stop swallowing echoes so the stroke gets captured.
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        ignoreEchoesUntilUserDraws = false
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        ignoreEchoesUntilUserDraws = false
    }

    /// Imperatively force the live canvas to the new page's ink at a page-turn commit, and suppress echo capture
    /// until the user next puts a tool down. Called synchronously from the container's page-turn commit (via
    /// `AnnotationCanvasHandle`) so the suppression is armed BEFORE any queued PencilKit `didChange` echo of the
    /// just-left page can run — the reactive `displayDrawing` path can't, since its byte guard is only armed at the
    /// next render. Unconditional assign (unlike `applyDrawing`'s byte-identity guard, which a stale same-instance
    /// echo could satisfy and skip — the original linger). Guard the canvas FIRST so a nil canvas never advances
    /// `lastSeededDrawing` past an un-applied seed (which would later read as byte-equal and silently skip).
    func reseedForPageTurn(_ drawing: PKDrawing) {
        guard let canvas else { return }
        ignoreEchoesUntilUserDraws = true
        lastSeededDrawing = drawing
        inkRightEdge = Self.rightEdge(of: drawing)
        // The undo stack is page-scoped: an undo after the turn would put the OLD page's ink onto the new one — and
        // it would be swallowed as an echo, leaving the canvas and the model disagreeing. A change made on the page
        // being left is still a change, though, so it is latched before the seed moves.
        if let seed = sessionSeedBytes {
            if canvas.drawing.dataRepresentation() != seed {
                changedOnEarlierPages = true
            }
            sessionSeedBytes = drawing.dataRepresentation()
            canvas.undoManager?.removeAllActions()
        }
        canvas.drawing = drawing
        publishSessionState()
    }

    /// Seed/replace the canvas only when the projected model actually changed (load or reflow); never echo the user's
    /// own in-progress edits back onto the canvas.
    private func applyDrawing(_ drawing: PKDrawing) {
        guard let canvas else { return }
        let bytes = drawing.dataRepresentation()
        if bytes != lastSeededDrawing.dataRepresentation() {
            lastSeededDrawing = drawing
            inkRightEdge = Self.rightEdge(of: drawing)
            if canvas.drawing.dataRepresentation() != bytes {
                // A reseed mid-session is a reflow re-projecting the same ink, not an edit: carry the baseline
                // forward while nothing has changed, so the strip keeps reading "unchanged". Once something HAS
                // changed the seed stays where it was — the ✕ restore works from the model, not from here. Either
                // way the undo stack is dropped: its actions would restore geometry the reflow just invalidated.
                if sessionSeedBytes != nil {
                    if !sessionHasChangesNow {
                        sessionSeedBytes = bytes
                    }
                    canvas.undoManager?.removeAllActions()
                }
                canvas.drawing = drawing
                publishSessionState()
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

    /// Also where the session's tracking (`AnnotationCanvasController+Session.swift`) begins and ends: the picker
    /// going up is the first moment the canvas is live, and it coming down is the last.
    private func applyToolPicker(visible: Bool) {
        guard let canvas else { return }
        if visible {
            guard canvas.window != nil else { return }
            let isNewSession = toolPicker == nil
            let picker = toolPicker ?? PKToolPicker()
            toolPicker = picker
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            canvas.becomeFirstResponder()
            if isNewSession {
                beginSessionTracking()
            }
        } else if let picker = toolPicker {
            picker.setVisible(false, forFirstResponder: canvas)
            picker.removeObserver(canvas)
            toolPicker = nil
            endSessionTracking()
        }
    }
}
#endif
