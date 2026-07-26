package com.keynumber.folino.reader.ink

import android.graphics.Matrix
import android.view.MotionEvent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.viewinterop.AndroidView
import androidx.ink.authoring.InProgressStrokeId
import androidx.ink.authoring.InProgressStrokesFinishedListener
import androidx.ink.authoring.InProgressStrokesView
import androidx.ink.brush.Brush
import androidx.ink.strokes.Stroke
import androidx.input.motionprediction.MotionEventPredictor

/**
 * Backstop for the wet→dry handoff: a finished stroke is never kept on the wet layer longer than this, even
 * if the dry layer never reports painting it. Comfortably above a commit round-trip on a large layer, and
 * short enough that a stranded stroke can't survive into a zoom (retained strokes don't follow the camera).
 */
private const val MAX_WET_RETENTION_MS = 2_000L

/**
 * Minimum span of the [MotionEvent.getEventTime] input timeline between two `MOVE`-phase
 * [AnnotationWetOverlay.onEraseGesture] emissions. Batches the eraser path so the erase consumer runs at a
 * steady cadence instead of once per touch sample.
 */
private const val ERASE_THROTTLE_MS = 50L

/** Phase of an in-progress eraser gesture reported to [AnnotationWetOverlay.onEraseGesture]. */
enum class ErasePhase { BEGIN, MOVE, END }

/** Maps a screen-px point through [matrix] (the overlay's `screenToWorld`) to a document-mm [Offset]. */
private fun mapToWorldMm(matrix: Matrix, x: Float, y: Float): Offset {
    val pts = floatArrayOf(x, y)
    matrix.mapPoints(pts)
    return Offset(pts[0], pts[1])
}

/**
 * Wet capture overlay: an `AndroidView`-wrapped androidx.ink `InProgressStrokesView`, sibling of `ScorePage`
 * inside the sized content `Box` (its local coords == content-Box px, per the doc-mm `worldToScreen` transform
 * supplied by the caller). Routes per-pointer: the first finger or stylus draws a wet stroke. If that stroke
 * was started by a stylus, a second pointer touching down (a palm) is rejected and the stroke keeps drawing
 * (spec §6.4: stylus always draws); otherwise a second pointer cancels the in-progress stroke and hands the
 * gesture back to the parent for pan/zoom. Finished strokes are handed to [onStrokeFinished] — this composable
 * does not anchor or persist anything itself.
 *
 * [onStrokeFinished] also receives a `release` callback. Until it runs, androidx.ink keeps rendering the
 * finished stroke, which is what covers the asynchronous commit (see [AnnotationHandoffQueue]); the caller
 * runs it once the dry layer has painted the committed stroke.
 *
 * When [eraserMode] is true, the touch path above is bypassed entirely: no wet stroke is started, and the
 * touched path (converted to document-mm) is instead batched to [onEraseGesture] — [ErasePhase.BEGIN] with
 * the first point, throttled [ErasePhase.MOVE] batches at [ERASE_THROTTLE_MS] along the input timeline, and
 * [ErasePhase.END] with the remainder on finger-up, a second pointer touching down, or a cancel. Actually
 * erasing strokes is handled downstream by the caller — this overlay only reports the gesture. Together the
 * emissions form one contiguous polyline: [ErasePhase.BEGIN]'s point is not repeated in the first
 * [ErasePhase.MOVE] batch, so the consumer must connect it to that batch's first point, and likewise connect
 * each batch's last point to the next batch's first point. [eraserMode] is latched per gesture at
 * `ACTION_DOWN`, so a tool switch mid-stroke takes effect on the next gesture rather than tearing this one.
 */
@Composable
fun AnnotationWetOverlay(
    worldToScreen: Matrix,
    brush: Brush,
    onStrokeFinished: (stroke: Stroke, release: () -> Unit) -> Unit,
    onTwoFingerGesture: () -> Unit,
    eraserMode: Boolean = false,
    onEraseGesture: (phase: ErasePhase, pathMm: List<Offset>) -> Unit = { _, _ -> },
    modifier: Modifier = Modifier,
) {
    val screenToWorld = remember { Matrix() }
    worldToScreen.invert(screenToWorld)

    // The AndroidView `factory` runs ONCE; its setOnTouchListener/finished-listener closures capture
    // these by reference. Route the mutable ones through rememberUpdatedState so a stroke started AFTER
    // the user changes color/tool uses the CURRENT brush (not the initial one captured at factory time),
    // and finished strokes go to the current callback.
    val currentBrush by rememberUpdatedState(brush)
    val currentOnStrokeFinished by rememberUpdatedState(onStrokeFinished)
    val currentOnTwoFinger by rememberUpdatedState(onTwoFingerGesture)
    val currentEraserMode by rememberUpdatedState(eraserMode)
    val currentOnEraseGesture by rememberUpdatedState(onEraseGesture)

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val view = InProgressStrokesView(ctx).apply { eagerInit() }
            val predictor = MotionEventPredictor.newInstance(view)
            val pointerToStroke = HashMap<Int, InProgressStrokeId>()
            var activeStylus = false

            // Eraser-mode-only state: no wet stroke exists while erasing, so this is a simple point buffer
            // rather than an androidx.ink stroke handle. `gestureIsErasing` is latched from `currentEraserMode`
            // at ACTION_DOWN and then used for the rest of THIS gesture — see the class doc's note on why:
            // re-reading currentEraserMode on every event would tear a gesture across branches if the tool is
            // switched mid-stroke by a second pointer elsewhere on screen (e.g. a toolbar toggle).
            val eraseAccum = mutableListOf<Offset>()
            var eraserPointerId = MotionEvent.INVALID_POINTER_ID
            var lastEraseEmitTime = 0L
            var gestureIsErasing = false

            view.addFinishedStrokesListener(object : InProgressStrokesFinishedListener {
                override fun onStrokesFinished(strokes: Map<InProgressStrokeId, Stroke>) {
                    // Deliberately NOT removeFinishedStrokes(...) here. The view goes on rendering a
                    // finished stroke until it is removed, and while the commit runs (off-main JNI capture,
                    // then an off-main placement recompute before the dry layer repaints) that is the only
                    // thing drawing it. Removing it in this callback is what made the ink blink out at
                    // finger-up. The caller releases each stroke once the dry layer has painted it; the
                    // backstop bounds the retention if that signal never arrives (an overlapping one-frame
                    // double-draw is invisible, a stroke stranded on the wet layer is not).
                    strokes.forEach { (id, stroke) ->
                        val remove = Runnable { view.removeFinishedStrokes(setOf(id)) }
                        view.postDelayed(remove, MAX_WET_RETENTION_MS)
                        currentOnStrokeFinished(stroke) {
                            view.removeCallbacks(remove)
                            remove.run()
                        }
                    }
                }
            })

            view.setOnTouchListener { v, event ->
                // Latch the mode for this gesture at its first pointer's DOWN only — see the class doc and
                // the comment by `gestureIsErasing`'s declaration. Every other action below rides the latch.
                if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                    gestureIsErasing = currentEraserMode
                }
                if (gestureIsErasing) {
                    // Eraser mode never starts a wet stroke and never touches the predictor — there is
                    // nothing androidx.ink-side to predict or record.
                    when (event.actionMasked) {
                        MotionEvent.ACTION_DOWN -> {
                            v.requestUnbufferedDispatch(event)
                            eraserPointerId = event.getPointerId(event.actionIndex)
                            eraseAccum.clear()
                            lastEraseEmitTime = event.eventTime
                            val p = mapToWorldMm(screenToWorld, event.x, event.y)
                            currentOnEraseGesture(ErasePhase.BEGIN, listOf(p))
                            true
                        }
                        MotionEvent.ACTION_POINTER_DOWN -> {
                            if (eraserPointerId == MotionEvent.INVALID_POINTER_ID) {
                                // Gesture already ended/handed off (e.g. a third pointer touching down
                                // after the real handoff below) — don't emit a second END, just keep
                                // falling through to the parent for pan/zoom.
                                return@setOnTouchListener false
                            }
                            // Mirrors the pen path's two-finger handoff: flush what's accumulated so far
                            // (already-erased ink stays erased) and hand the gesture to the parent for
                            // pan/zoom. The eraser has no stylus-always-erases rule. eraserPointerId is
                            // cleared so the guards below on the still-live finger-1 events (Android keeps
                            // delivering them to this view even after this arm returns false) turn into a
                            // no-op instead of a duplicate END.
                            currentOnEraseGesture(ErasePhase.END, eraseAccum.toList())
                            eraseAccum.clear()
                            eraserPointerId = MotionEvent.INVALID_POINTER_ID
                            false
                        }
                        MotionEvent.ACTION_MOVE -> {
                            if (eraserPointerId == MotionEvent.INVALID_POINTER_ID) return@setOnTouchListener true
                            val idx = event.findPointerIndex(eraserPointerId)
                            if (idx != -1) {
                                // Batched historical samples first, so a fast drag doesn't coarsen the
                                // polyline or skip gaps between MotionEvent deliveries.
                                for (h in 0 until event.historySize) {
                                    eraseAccum.add(
                                        mapToWorldMm(screenToWorld, event.getHistoricalX(idx, h), event.getHistoricalY(idx, h)),
                                    )
                                }
                                eraseAccum.add(mapToWorldMm(screenToWorld, event.getX(idx), event.getY(idx)))
                            }
                            if (event.eventTime - lastEraseEmitTime >= ERASE_THROTTLE_MS) {
                                currentOnEraseGesture(ErasePhase.MOVE, eraseAccum.toList())
                                eraseAccum.clear()
                                lastEraseEmitTime = event.eventTime
                            }
                            true
                        }
                        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                            if (eraserPointerId == MotionEvent.INVALID_POINTER_ID) return@setOnTouchListener true
                            currentOnEraseGesture(ErasePhase.END, eraseAccum.toList())
                            eraseAccum.clear()
                            eraserPointerId = MotionEvent.INVALID_POINTER_ID
                            true
                        }
                        else -> false
                    }
                } else {
                    predictor.record(event)
                    when (event.actionMasked) {
                        MotionEvent.ACTION_DOWN -> {
                            v.requestUnbufferedDispatch(event)
                            val pid = event.getPointerId(event.actionIndex)
                            pointerToStroke[pid] = view.startStroke(event, pid, currentBrush, screenToWorld)
                            activeStylus = event.getToolType(event.actionIndex) == MotionEvent.TOOL_TYPE_STYLUS
                            true
                        }
                        MotionEvent.ACTION_POINTER_DOWN -> {
                            if (pointerToStroke.isNotEmpty() && activeStylus) {
                                // Stylus is drawing (spec §6.4: stylus always draws) — reject the extra
                                // finger/palm, keep the stroke.
                                true // consume so the parent doesn't start pan/zoom
                            } else {
                                // Two fingers => navigate. Abort the wet stroke, hand the gesture to the parent.
                                pointerToStroke.values.forEach { view.cancelStroke(it, event) }
                                pointerToStroke.clear()
                                activeStylus = false
                                currentOnTwoFinger()
                                false
                            }
                        }
                        MotionEvent.ACTION_MOVE -> {
                            val predicted = predictor.predict()
                            try {
                                for (i in 0 until event.pointerCount) {
                                    val sid = pointerToStroke[event.getPointerId(i)] ?: continue
                                    view.addToStroke(event, event.getPointerId(i), sid, predicted)
                                }
                            } finally {
                                predicted?.recycle()
                            }
                            true
                        }
                        MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                            val pid = event.getPointerId(event.actionIndex)
                            pointerToStroke.remove(pid)?.let { view.finishStroke(event, pid, it) }
                            if (pointerToStroke.isEmpty()) activeStylus = false
                            true
                        }
                        MotionEvent.ACTION_CANCEL -> {
                            pointerToStroke.values.forEach { view.cancelStroke(it, event) }
                            pointerToStroke.clear()
                            activeStylus = false
                            true
                        }
                        else -> false
                    }
                }
            }
            view
        },
        update = { worldToScreen.invert(screenToWorld) },
    )
}
