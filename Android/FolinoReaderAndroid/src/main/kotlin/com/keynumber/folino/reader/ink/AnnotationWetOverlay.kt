package com.keynumber.folino.reader.ink

import android.graphics.Matrix
import android.view.MotionEvent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.ink.authoring.InProgressStrokeId
import androidx.ink.authoring.InProgressStrokesFinishedListener
import androidx.ink.authoring.InProgressStrokesView
import androidx.ink.brush.Brush
import androidx.ink.strokes.Stroke
import androidx.input.motionprediction.MotionEventPredictor

/**
 * Wet capture overlay: an `AndroidView`-wrapped androidx.ink `InProgressStrokesView`, sibling of `ScorePage`
 * inside the sized content `Box` (its local coords == content-Box px, per the doc-mm `worldToScreen` transform
 * supplied by the caller). Routes per-pointer: the first finger or stylus draws a wet stroke. If that stroke
 * was started by a stylus, a second pointer touching down (a palm) is rejected and the stroke keeps drawing
 * (spec §6.4: stylus always draws); otherwise a second pointer cancels the in-progress stroke and hands the
 * gesture back to the parent for pan/zoom. Finished strokes are handed to [onStrokeFinished] — this composable
 * does not anchor or persist anything itself.
 */
@Composable
fun AnnotationWetOverlay(
    worldToScreen: Matrix,
    brush: Brush,
    onStrokeFinished: (Stroke) -> Unit,
    onTwoFingerGesture: () -> Unit,
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

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val view = InProgressStrokesView(ctx).apply { eagerInit() }
            val predictor = MotionEventPredictor.newInstance(view)
            val pointerToStroke = HashMap<Int, InProgressStrokeId>()
            var activeStylus = false

            view.addFinishedStrokesListener(object : InProgressStrokesFinishedListener {
                override fun onStrokesFinished(strokes: Map<InProgressStrokeId, Stroke>) {
                    strokes.values.forEach(currentOnStrokeFinished)
                    view.removeFinishedStrokes(strokes.keys) // same frame — avoids wet/dry double-draw
                }
            })

            view.setOnTouchListener { v, event ->
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
            view
        },
        update = { worldToScreen.invert(screenToWorld) },
    )
}
