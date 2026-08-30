package com.keynumber.folino.reader

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.calculateTargetValue
import androidx.compose.animation.core.tween
import androidx.compose.animation.splineBasedDecay
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs

// The transport's swipe-to-resize gesture: swipe the playback controls right to shrink them to the floating
// cluster, left to bring the seek card back.
//
// EVERY THRESHOLD AND CURVE HERE COMES FROM SWIFT. `ReaderInteractionCore.TransportModeSwipe` owns the commit
// distance, the rubber band, the release velocity and the animation pacing, and iOS's `ReaderTransportControl`
// calls exactly the same functions through `TransportModeSwipe+SwiftUI`. This file is the Compose half — the
// pointer plumbing and the animation objects — and decides nothing about how the gesture feels.

/** `TransportModeSwipeOutcome.rawValue`, as `nativeTransportSwipeOutcome` returns it. */
private const val OUTCOME_COLLAPSE = 0
private const val OUTCOME_EXPAND = 1

/**
 * Live state for one transport. Hoisted to the Reader because the two forms it switches between are two different
 * composables — the committed mode has to decide which of them is mounted, so it cannot live inside either.
 */
class TransportModeSwipeState internal constructor(
    private val scope: CoroutineScope,
    private val density: Density,
) {
    /** The persisted preference. Written by the owner; read here as the mode to fall back on. */
    internal var showSeekBar: Boolean = true

    /** Takes a committed swipe, or declines it (an edit session does). Returns whether it was taken. */
    internal var onSetSeekBarVisible: (Boolean) -> Boolean = { false }

    /**
     * The mode the transport holds from the moment a swipe commits until the preference catches up, and `null` when
     * it is simply following the preference.
     *
     * Local rather than deferred to the preference: that write is delayed on purpose (see
     * `TransportModeSwipe.preferenceCommitDelay`), and a *flicked* swipe — which commits on its projection without
     * ever crossing the threshold — would otherwise have nothing to glide into.
     */
    private var previewSeekBar by mutableStateOf<Boolean?>(null)

    /**
     * Where the control sits. Two sources, never both: the rubber-banded finger travel while a swipe is in progress,
     * and the animation that unwinds it after release. Splitting them keeps the live drag off the animation clock —
     * snapping an `Animatable` once per pointer event would put every frame of the follow behind a coroutine.
     */
    private var isDragging by mutableStateOf(false)
    private var dragOffsetPx by mutableFloatStateOf(0f)
    private val settleOffsetPx = Animatable(0f)

    val offsetPx: Float get() = if (isDragging) dragOffsetPx else settleOffsetPx.value

    private var settleJob: Job? = null

    /** The form to draw right now. */
    val rendersSeekBar: Boolean get() = previewSeekBar ?: showSeekBar

    /**
     * How long the form change caused by the last committed swipe should take — paced by how fast the finger was
     * moving when it let go, so a flick gets a swap that keeps up with it and a deliberate drag gets the long one.
     * Seeded with the deliberate pace, which is also what an acted-out coach mark uses.
     */
    var modeSwapMillis by mutableStateOf(FolinoReaderJNI.nativeTransportModeSwapDurationMillis(0.0))
        private set

    internal fun syncPreference(showSeekBar: Boolean) {
        this.showSeekBar = showSeekBar
        // Drop the local hold once the preference agrees — from here the two say the same thing.
        if (previewSeekBar == showSeekBar) previewSeekBar = null
    }

    /**
     * Switches modes because the swipe coach mark was tapped, by acting the swipe out rather than just flipping:
     * the control slides one commit distance in the direction the finger would have gone, the form changes under it,
     * and the same release animation carries it home. Someone who has never found the gesture sees what it does and
     * where their finger has to go.
     *
     * Paced as a DELIBERATE swipe (speed 0 floors to `deliberateSwipeSpeed`), not a flick: this is a demonstration,
     * and the slow curves are the legible ones.
     */
    fun performHintedModeSwitch() {
        val target = !rendersSeekBar
        if (!onSetSeekBarVisible(target)) return
        // Expanded collapses on a right swipe, compact expands on a left one.
        val travelDp = FolinoReaderJNI.nativeTransportCommitDistance() * if (target) -1 else 1
        val travelPx = with(density) { travelDp.dp.toPx() }
        modeSwapMillis = FolinoReaderJNI.nativeTransportModeSwapDurationMillis(0.0)
        previewSeekBar = target
        settleJob?.cancel()
        isDragging = false
        settleJob = scope.launch {
            settleOffsetPx.animateTo(travelPx, tween(FolinoReaderJNI.nativeTransportHintedSwipeOutMillis()))
            delay(SETTLE_HOLD_MILLIS)
            settleOffsetPx.animateTo(0f, tween(FolinoReaderJNI.nativeTransportSettleDurationMillis(0.0)))
        }
    }

    /**
     * Tracks the finger. The form itself does NOT change until release.
     *
     * iOS flips the card under the finger the moment the swipe passes the commit threshold, because there the
     * transport is ONE view that morphs between two sizes. Android's two forms are two different composables in two
     * different Scaffold slots (`bottomBar` and `floatingActionButton`), so flipping mid-drag would unmount the very
     * node the pointer stream belongs to and the gesture would die half-finished, leaving the control displaced.
     * The rubber band is what says the swipe is going somewhere; the commit lands on release, judged by exactly the
     * same shared `outcome`.
     */
    internal fun onDrag(translationXPx: Float, translationYPx: Float) {
        settleJob?.cancel()
        isDragging = true
        val translationDp = with(density) { translationXPx.toDp().value.toDouble() }
        dragOffsetPx = with(density) {
            FolinoReaderJNI.nativeTransportFollowOffset(translationDp, showSeekBar).dp.toPx()
        }
    }

    /**
     * The node carrying the gesture left the composition (the form changed, the Reader was left) while a swipe was
     * still in progress. There is no release to judge, so the control just goes home rather than staying displaced.
     */
    internal fun onGestureNodeDisposed() {
        if (!isDragging) return
        onDragCancel()
    }

    internal fun onDragEnd(
        translationXPx: Float,
        translationYPx: Float,
        velocityXPx: Float,
        predictedEndXPx: Float,
    ) {
        val translationDp = with(density) { translationXPx.toDp().value.toDouble() }
        val translationYDp = with(density) { translationYPx.toDp().value.toDouble() }
        val predictedDp = with(density) { predictedEndXPx.toDp().value.toDouble() }
        val velocityDp = with(density) { velocityXPx.toDp().value.toDouble() }

        val settled = when (
            FolinoReaderJNI.nativeTransportSwipeOutcome(translationDp, translationYDp, predictedDp)
        ) {
            OUTCOME_COLLAPSE -> if (onSetSeekBarVisible(false)) false else null
            OUTCOME_EXPAND -> if (onSetSeekBarVisible(true)) true else null
            else -> null
        }
        previewSeekBar = settled
        if (settled != null) modeSwapMillis = FolinoReaderJNI.nativeTransportModeSwapDurationMillis(velocityDp)

        // Freeze the damped travel into the settle animation before handing the frame over, so the control does not
        // blink back to its edge as the gesture state evaporates.
        val released = dragOffsetPx
        val releaseVelocity = with(density) {
            FolinoReaderJNI.nativeTransportSettleVelocity(
                velocityDp, -released.toDp().value.toDouble(),
            ).dp.toPx()
        }
        settleJob?.cancel()
        settleJob = scope.launch {
            settleOffsetPx.snapTo(released)
            isDragging = false
            settleOffsetPx.animateTo(
                0f,
                tween(FolinoReaderJNI.nativeTransportSettleDurationMillis(velocityDp)),
                // A finger still moving outward at release keeps its velocity, so the control coasts a touch
                // further before turning round — which is what momentum looks like. The shared clamp is what
                // stops a gentle release from being catapulted by what little travel is left.
                initialVelocity = releaseVelocity,
            )
        }
    }

    internal fun onDragCancel() {
        val released = dragOffsetPx
        settleJob?.cancel()
        settleJob = scope.launch {
            settleOffsetPx.snapTo(released)
            isDragging = false
            settleOffsetPx.animateTo(0f, tween(FolinoReaderJNI.nativeTransportSettleDurationMillis(0.0)))
        }
    }

    private companion object {
        /** A beat at full travel, so the acted-out swipe reads as a gesture rather than a bounce. */
        const val SETTLE_HOLD_MILLIS = 60L
    }
}

/**
 * Holds the swipe state for this Reader, kept in step with the persisted preference.
 *
 * @param showSeekBar the stored preference.
 * @param onSetSeekBarVisible takes a committed swipe (deferring the write — see
 *   `TransportModeSwipe.preferenceCommitDelay`) and answers whether it was taken; declining leaves the control to
 *   animate back, which is what an edit session does.
 */
@Composable
fun rememberTransportModeSwipe(
    showSeekBar: Boolean,
    onSetSeekBarVisible: (Boolean) -> Boolean,
): TransportModeSwipeState {
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val state = remember(scope, density) { TransportModeSwipeState(scope, density) }
    state.syncPreference(showSeekBar)
    state.onSetSeekBarVisible = onSetSeekBarVisible
    return state
}

/**
 * Makes a transport row (or the floating cluster) swipeable to switch modes.
 *
 * The detector runs in the **Initial** pass and claims the gesture only once the travel is horizontal and past touch
 * slop. That is what lets the drag coexist with the buttons underneath: a tap never travels far enough to be claimed,
 * so the button gets it; once the finger does travel, the drag consumes and the button it started on is cancelled
 * rather than fired on release. It is Compose's reading of iOS's `highPriorityGesture` on the same row.
 */
@Composable
fun Modifier.transportModeSwipe(state: TransportModeSwipeState): Modifier {
    DisposableEffect(state) { onDispose { state.onGestureNodeDisposed() } }
    return pointerInput(state) {
        // Android's own fling projection, and the analogue of the `predictedEndTranslation` SwiftUI hands iOS — the
        // shared `outcome` needs one to let a fast, short flick commit without the finger ever travelling the full
        // commit distance.
        val decay = splineBasedDecay<Float>(this)
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            val tracker = VelocityTracker()
            tracker.addPosition(down.uptimeMillis, down.position)
            var total = Offset.Zero
            var claimed = false

            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                val change = event.changes.firstOrNull { it.id == down.id }
                if (change == null) {
                    // The pointer vanished mid-gesture (another window took the touch, the view was detached).
                    // There is no release to judge, so the control just goes home.
                    if (claimed) state.onDragCancel()
                    break
                }
                if (change.changedToUpIgnoreConsumed()) {
                    if (claimed) {
                        val velocityX = tracker.calculateVelocity().x
                        state.onDragEnd(
                            translationXPx = total.x,
                            translationYPx = total.y,
                            velocityXPx = velocityX,
                            predictedEndXPx = total.x + decay.calculateTargetValue(0f, velocityX),
                        )
                    }
                    break
                }
                total += change.positionChange()
                tracker.addPosition(change.uptimeMillis, change.position)
                if (!claimed && abs(total.x) > viewConfiguration.touchSlop && abs(total.x) >= abs(total.y)) {
                    claimed = true
                }
                if (claimed) {
                    change.consume()
                    state.onDrag(total.x, total.y)
                }
            }
        }
    }
}
