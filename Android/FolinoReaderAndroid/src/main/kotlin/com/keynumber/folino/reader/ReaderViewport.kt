package com.keynumber.folino.reader

import androidx.compose.animation.core.AnimationState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDecay
import androidx.compose.animation.core.animateTo
import androidx.compose.animation.core.spring
import androidx.compose.animation.splineBasedDecay
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Velocity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlin.math.abs

/** Lower bound of the reader's pinch zoom: fit. Zooming out past fit is deliberately not offered. */
internal const val MIN_READER_SCALE = 1f

/** Upper bound of the reader's pinch zoom. */
internal const val MAX_READER_SCALE = 8f

/**
 * Where content sits along one axis when it is SMALLER than the viewport — the case where there is no
 * scrolling to do and the offset is decided rather than chosen.
 *
 * [START] pins it to the leading edge (the vertical surface's top-anchored page). [CENTER] centers it
 * (the horizontal surface's single system, which floats in the middle of a taller viewport).
 */
internal enum class ViewportUnderfill { START, CENTER }

/**
 * Content extent along one axis at [scale], in px.
 *
 * [unitContentPx] is the part that scales with zoom (the page itself at scale 1); [fixedPadPx] is
 * padding that does NOT scale — the vertical surface's breathing room above and below the page, plus its
 * extra bottom pad that lets the last system clear the floating play button.
 */
internal fun axisContentPx(unitContentPx: Float, fixedPadPx: Float, scale: Float): Float =
    unitContentPx * scale + fixedPadPx

/**
 * Clamp a scroll offset along one axis.
 *
 * Positive offset means scrolled forward (down / right), matching `ScrollState.value`. When the content
 * is larger than the viewport the offset rides in `[0, contentPx - viewportPx]`. When it is smaller
 * there is nothing to scroll and [underfill] decides: [ViewportUnderfill.START] pins to zero;
 * [ViewportUnderfill.CENTER] returns a negative offset of half the gap, which the layer's
 * `translation = -offset` turns into a positive lead-in.
 */
internal fun clampAxisOffset(
    offset: Float,
    contentPx: Float,
    viewportPx: Float,
    underfill: ViewportUnderfill,
): Float = if (contentPx <= viewportPx) {
    when (underfill) {
        ViewportUnderfill.START -> 0f
        ViewportUnderfill.CENTER -> (contentPx - viewportPx) / 2f
    }
} else {
    offset.coerceIn(0f, contentPx - viewportPx)
}

/**
 * New scroll offset (px) that keeps the content point under the pinch centroid fixed across a zoom step
 * of ratio `r = newScale / oldScale`. Only the page content scales by `r`; a constant leading [pad] (the
 * fixed padding before the page, which does NOT scale with zoom) is held out of the scaling.
 *
 * In scroll space the content point under the centroid is at `scroll + centroid`; the scaling page part
 * is `scroll + centroid - pad`, so after scaling by `r` the new offset is
 * `pad + r * (scroll - pad + centroid) - centroid`. With `pad = 0` this reduces to the simple
 * `r * (scroll + centroid) - centroid`.
 *
 * The result is NOT clamped here. Clamping is the caller's job and has to happen against the content
 * extent at the NEW scale — the scroll state's clamping at the old extent would have dragged the anchor
 * to the top-left, since the container's `maxValue` still described the previous frame's layout. A caller
 * moving to the new scale must recompute the content extents and clamp the result against those.
 */
internal fun focalAdjustedOffset(
    currentScroll: Float,
    centroid: Float,
    ratio: Float,
    pad: Float = 0f,
): Float = pad + ratio * (currentScroll - pad + centroid) - centroid

/** Clamp a proposed zoom into the reader's supported range. */
internal fun coerceReaderScale(scale: Float): Float = scale.coerceIn(MIN_READER_SCALE, MAX_READER_SCALE)

/**
 * Everything a [ReaderViewportState] needs from its surface's layout, in px, republished on every
 * composition that changes it.
 *
 * The scaling and non-scaling parts are kept apart because clamping has to be evaluated at a scale the
 * layout has not run at yet — mid-pinch, the extent for the frame being computed does not exist in any
 * measured node. [unitContentWidthPx] / [unitContentHeightPx] are the content at scale 1;
 * [fixedPadXPx] / [fixedPadYPx] are padding that never scales; [leadingPadYPx] is the part of the fixed
 * vertical padding that sits BEFORE the content, which the focal correction has to hold out of the
 * scaling.
 */
internal data class ViewportGeometry(
    val viewportWidthPx: Float = 0f,
    val viewportHeightPx: Float = 0f,
    val unitContentWidthPx: Float = 0f,
    val unitContentHeightPx: Float = 0f,
    val fixedPadXPx: Float = 0f,
    val fixedPadYPx: Float = 0f,
    val leadingPadYPx: Float = 0f,
)

/**
 * The reader's viewport: a zoom plus a two-dimensional offset, replacing the pair of Compose scroll
 * containers the vertical and horizontal surfaces used to nest.
 *
 * Offsets follow `ScrollState.value`: positive means scrolled forward (down / right). The surface turns
 * that into a layer transform with `translation = -offset`, so every consumer downstream — tap-to-cursor,
 * the auto-follow keep-in-view calls over JNI, the ink overlays — reads the same sign it always did.
 *
 * @param deferRaster true when the surface records its score at [rasterScale] and lets a layer transform
 *   cover the difference during a gesture (the vertical surface, whose score is one page as tall as the
 *   whole document). False when the surface re-records per frame, which is affordable for a single row or
 *   a single page; [rasterScale] then simply tracks [scale].
 */
internal class ReaderViewportState(
    private val deferRaster: Boolean,
    private val underfillX: ViewportUnderfill,
    private val underfillY: ViewportUnderfill,
) {
    var scale by mutableFloatStateOf(1f)
        private set

    /** The scale the score's draw commands were last recorded at. See [deferRaster]. */
    var rasterScale by mutableFloatStateOf(1f)
        private set

    var offsetX by mutableFloatStateOf(0f)
        private set

    var offsetY by mutableFloatStateOf(0f)
        private set

    private var geometryState by mutableStateOf(ViewportGeometry())

    /**
     * Layout inputs, republished by the surface whenever they move.
     *
     * Assigning re-clamps both offsets, because a geometry change can shrink the content out from under a
     * position that was legal a frame ago — a rotation, a resize, or a display-setting change that reflows
     * the score shorter. `ScrollState` coerced its value whenever `maxValue` shrank; without this, the
     * surface would render scrolled past the end of the score until the reader's next gesture.
     */
    var geometry: ViewportGeometry
        get() = geometryState
        set(value) {
            if (value == geometryState) return
            geometryState = value
            offsetX = clampX(offsetX)
            offsetY = clampY(offsetY)
        }

    private var flingJob: Job? = null

    // Whoever moved the viewport most recently owns it. A programmatic animation captures the generation it
    // started at and abandons its trajectory the moment something else claims the axis, instead of writing
    // over it every frame. `ScrollState` got this from `ScrollableState`'s `MutatorMutex`, which cancelled a
    // running `animateScrollTo` when a drag arrived at user-input priority; nothing here would otherwise stop
    // an auto-follow re-pin from fighting the reader's finger for the rest of its spring. Per axis, because
    // the vertical surface's auto-follow animates Y and X from one coroutine and a shared counter would have
    // the X call cancel the Y animation.
    private var motionGenerationX = 0
    private var motionGenerationY = 0

    /** Claim both axes for the reader — called when a finger lands, so any programmatic motion stands down. */
    fun interruptMotion() {
        cancelFling()
        motionGenerationX++
        motionGenerationY++
    }

    private fun clampX(value: Float, atScale: Float = scale): Float = clampAxisOffset(
        value,
        axisContentPx(geometry.unitContentWidthPx, geometry.fixedPadXPx, atScale),
        geometry.viewportWidthPx,
        underfillX,
    )

    private fun clampY(value: Float, atScale: Float = scale): Float = clampAxisOffset(
        value,
        axisContentPx(geometry.unitContentHeightPx, geometry.fixedPadYPx, atScale),
        geometry.viewportHeightPx,
        underfillY,
    )

    // Named `snap…`, not `setOffset…`: `offsetX` / `offsetY` are `private set` properties, so Kotlin already
    // synthesises `setOffsetX(Float)` / `setOffsetY(Float)` on the JVM and an explicit function of that name
    // is a platform declaration clash. `snap` also reads as the no-animation counterpart to `animateOffsetXTo`.
    fun snapOffsetX(value: Float) { offsetX = clampX(value) }

    fun snapOffsetY(value: Float) { offsetY = clampY(value) }

    /** Pan by a finger delta. The content follows the finger, so the offset moves the other way. */
    fun applyPan(pan: Offset) {
        offsetX = clampX(offsetX - pan.x)
        offsetY = clampY(offsetY - pan.y)
    }

    /**
     * Zoom by [zoomFactor] about [centroid] (viewport px), holding the content point under the centroid
     * fixed. Clamped against the extent at the NEW scale — see [focalAdjustedOffset].
     */
    fun applyZoom(zoomFactor: Float, centroid: Offset) {
        if (centroid.x.isNaN() || centroid.y.isNaN()) return
        val newScale = coerceReaderScale(scale * zoomFactor)
        val ratio = newScale / scale
        if (ratio == 1f) return
        val focalX = focalAdjustedOffset(offsetX, centroid.x, ratio)
        val focalY = focalAdjustedOffset(offsetY, centroid.y, ratio, geometry.leadingPadYPx)
        scale = newScale
        if (!deferRaster) rasterScale = newScale
        offsetX = clampX(focalX, newScale)
        offsetY = clampY(focalY, newScale)
    }

    /** Re-record the score at the scale it is now shown at. No-op when the scale did not move. */
    fun settleRaster() { if (rasterScale != scale) rasterScale = scale }

    fun reset() {
        interruptMotion()
        scale = 1f
        rasterScale = 1f
        offsetX = clampX(0f, 1f)
        offsetY = clampY(0f, 1f)
    }

    suspend fun animateOffsetXTo(target: Float) {
        val generation = ++motionGenerationX
        AnimationState(initialValue = offsetX).animateTo(clampX(target), AUTO_FOLLOW_SPEC) {
            if (generation != motionGenerationX) {
                cancelAnimation()
                return@animateTo
            }
            offsetX = clampX(value)
        }
    }

    suspend fun animateOffsetYTo(target: Float) {
        val generation = ++motionGenerationY
        AnimationState(initialValue = offsetY).animateTo(clampY(target), AUTO_FOLLOW_SPEC) {
            if (generation != motionGenerationY) {
                cancelAnimation()
                return@animateTo
            }
            offsetY = clampY(value)
        }
    }

    fun cancelFling() {
        flingJob?.cancel()
        flingJob = null
    }

    /**
     * Coast on after the fingers lift. [velocity] is the pointer's, so each axis is negated into offset
     * space. Each axis stops on its own the moment it reaches an edge — there is no rubber-band, so a
     * fling into the end of the score simply stops there.
     */
    fun startFling(scope: CoroutineScope, density: Density, velocity: Velocity) {
        cancelFling()
        if (abs(velocity.x) < 1f && abs(velocity.y) < 1f) return
        // The coast drives both axes, so it claims both. An auto-follow re-pin arriving mid-coast bumps the
        // axis it animates and takes it cleanly, instead of the decay and the spring writing alternate frames.
        val generationX = ++motionGenerationX
        val generationY = ++motionGenerationY
        flingJob = scope.launch {
            val decay = splineBasedDecay<Float>(density)
            coroutineScope {
                launch {
                    AnimationState(initialValue = offsetX, initialVelocity = -velocity.x)
                        .animateDecay(decay) {
                            if (generationX != motionGenerationX) {
                                cancelAnimation()
                                return@animateDecay
                            }
                            val clamped = clampX(value)
                            offsetX = clamped
                            if (clamped != value) cancelAnimation()
                        }
                }
                launch {
                    AnimationState(initialValue = offsetY, initialVelocity = -velocity.y)
                        .animateDecay(decay) {
                            if (generationY != motionGenerationY) {
                                cancelAnimation()
                                return@animateDecay
                            }
                            val clamped = clampY(value)
                            offsetY = clamped
                            if (clamped != value) cancelAnimation()
                        }
                }
            }
        }
    }

    private companion object {
        /**
         * Spec for the auto-follow re-pin, standing in for what `ScrollState.animateScrollTo` used to
         * provide. This is the knob to turn if the playback re-pin reads as too eager or too sluggish.
         */
        val AUTO_FOLLOW_SPEC = spring<Float>(stiffness = Spring.StiffnessMediumLow, visibilityThreshold = 0.5f)
    }
}

@Composable
internal fun rememberReaderViewportState(
    deferRaster: Boolean,
    underfillX: ViewportUnderfill,
    underfillY: ViewportUnderfill,
): ReaderViewportState = remember(deferRaster, underfillX, underfillY) {
    ReaderViewportState(deferRaster, underfillX, underfillY)
}

/**
 * The reader's one gesture loop: free two-dimensional panning, a pinch that pans at the same time, and
 * momentum when the fingers lift.
 *
 * This deliberately replaces `Modifier.verticalScroll` + `Modifier.horizontalScroll`. Those are two
 * independent `scrollable` modifiers, and whichever one's drag detector wins the pointer slop owns the
 * gesture for its duration — which is why a diagonal drag used to resolve onto an axis and stay there.
 *
 * Movement is observed on the Initial pass and consumed, so a pan cancels the sibling
 * `detectTapGestures` that would otherwise seek. Single-finger panning waits for touch slop first: a tap
 * that wobbles a pixel has to stay a tap, or seeking becomes unreliable.
 *
 * @param scope must be composition-scoped (`rememberCoroutineScope()`), not something longer-lived like a
 *   `viewModelScope`. [ReaderViewportState.startFling] launches into it, and a scope that outlives the
 *   composition would let the decay animation keep running after the composable is gone, writing into a
 *   detached [state].
 * @param key extra `pointerInput` restart key, on top of [state] and the flags below. Anything that
 *   changes the gesture's meaning and is stable across a gesture belongs here.
 * @param allowSingleFingerPan a LAMBDA, evaluated per event rather than captured. The page surface's
 *   answer depends on the live zoom (`scale > 1f`, so `HorizontalPager` keeps its swipe at fit), and a
 *   value read into the `pointerInput` key list would restart the handler mid-pinch and abort the
 *   gesture the instant the zoom crossed 1. False while annotating on every surface — a single finger
 *   is a stroke there. The lambda body must read live observable state, never a value captured from the
 *   enclosing composition: `pointerInput` deliberately does not restart on the lambda's identity, so a
 *   captured value goes stale and reproduces the exact mid-pinch bug this parameter exists to prevent.
 * @param allowFling false while annotating — coasting away from where the reader is writing loses their
 *   place. Safe as a plain value: it only changes when the pen is armed or put away.
 * @param onManualViewportChange fired once per gesture, on two-finger contact or on the first real
 *   single-finger movement. Suspends the playback auto-follow. Firing on pointer MOVEMENT rather than on
 *   a scroll-in-progress flag is load-bearing: a programmatic auto-follow re-pin emits no pointer input,
 *   so this can never mistake the auto-scroll's own animation for a gesture and latch suspension on.
 */
internal fun Modifier.readerViewportGestures(
    state: ReaderViewportState,
    scope: CoroutineScope,
    key: Any?,
    enabled: Boolean,
    allowSingleFingerPan: () -> Boolean,
    allowFling: Boolean,
    onManualViewportChange: () -> Unit,
): Modifier = pointerInput(state, key, enabled, allowFling) {
    if (!enabled) return@pointerInput
    val slop = viewConfiguration.touchSlop
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false)
        state.interruptMotion()
        val tracker = VelocityTracker()
        var notifiedManual = false
        var panned = false
        var pastSlop = false
        var travelled = Offset.Zero
        var event: PointerEvent
        try {
            do {
                event = awaitPointerEvent(PointerEventPass.Initial)
                val pressed = event.changes.count { it.pressed }
                if (pressed >= 2) {
                    if (!notifiedManual) {
                        onManualViewportChange()
                        notifiedManual = true
                    }
                    // `calculateCentroid` counts only changes with `pressed && previousPressed`, so on the
                    // frame a finger lifts it is excluded from BOTH centroids and `calculatePan` returns the
                    // remaining finger's own delta rather than a centroid snap. Do not "fix" this by
                    // computing the centroid over all changes — an asymmetric finger lift is exactly what
                    // made the iOS pinch jump.
                    val centroid = event.calculateCentroid(useCurrent = true)
                    if (!centroid.x.isNaN() && !centroid.y.isNaN()) {
                        val zoom = event.calculateZoom()
                        if (zoom != 1f) state.applyZoom(zoom, centroid)
                        val pan = event.calculatePan()
                        if (pan != Offset.Zero) {
                            state.applyPan(pan)
                            panned = true
                        }
                    }
                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                    // A pinch does not seed the fling: the two-finger centroid is a poor velocity signal and
                    // coasting out of a zoom feels like a slip rather than a throw.
                    tracker.resetTracking()
                    pastSlop = true
                } else if (pressed == 1 && allowSingleFingerPan()) {
                    val change = event.changes.first { it.pressed }
                    val pan = event.calculatePan()
                    if (!pastSlop) {
                        travelled += pan
                        if (travelled.getDistance() >= slop) pastSlop = true
                    }
                    if (pastSlop && pan != Offset.Zero) {
                        if (!notifiedManual) {
                            onManualViewportChange()
                            notifiedManual = true
                        }
                        state.applyPan(pan)
                        panned = true
                        tracker.addPosition(change.uptimeMillis, change.position)
                        change.consume()
                    }
                }
            } while (event.changes.any { it.pressed })
            if (allowFling && panned) {
                state.startFling(scope, this@pointerInput, tracker.calculateVelocity())
            }
        } finally {
            state.settleRaster()
        }
    }
}
