package com.keynumber.folino.reader.ink

import android.graphics.Matrix
import android.view.MotionEvent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
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
 * supplied by the caller). Routes per-pointer: the first finger or stylus draws a wet stroke; a second pointer
 * touching down cancels the in-progress stroke and hands the gesture back to the parent for pan/zoom. Finished
 * strokes are handed to [onStrokeFinished] — this composable does not anchor or persist anything itself.
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

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val view = InProgressStrokesView(ctx).apply { eagerInit() }
            val predictor = MotionEventPredictor.newInstance(view)
            val pointerToStroke = HashMap<Int, InProgressStrokeId>()

            view.addFinishedStrokesListener(object : InProgressStrokesFinishedListener {
                override fun onStrokesFinished(strokes: Map<InProgressStrokeId, Stroke>) {
                    strokes.values.forEach(onStrokeFinished)
                    view.removeFinishedStrokes(strokes.keys) // same frame — avoids wet/dry double-draw
                }
            })

            view.setOnTouchListener { v, event ->
                predictor.record(event)
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        v.requestUnbufferedDispatch(event)
                        val pid = event.getPointerId(event.actionIndex)
                        pointerToStroke[pid] = view.startStroke(event, pid, brush, screenToWorld)
                        true
                    }
                    MotionEvent.ACTION_POINTER_DOWN -> {
                        // 2nd pointer => this is pan/zoom. Abort the wet stroke, hand the gesture to the parent.
                        pointerToStroke.values.forEach { view.cancelStroke(it, event) }
                        pointerToStroke.clear()
                        onTwoFingerGesture()
                        false
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
                        true
                    }
                    MotionEvent.ACTION_CANCEL -> {
                        pointerToStroke.values.forEach { view.cancelStroke(it, event) }
                        pointerToStroke.clear()
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
