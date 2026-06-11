package com.keynumber.folino.reader.ui

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * A Material3 [Slider] that exposes a "reset to default" affordance, mirroring the iOS
 * `ResettableSlider`: a small tick drawn at the default position along the track, and a
 * double-tap anywhere on the slider that snaps the value back to [defaultValue].
 *
 * **Double-tap detection.** A Material3 Slider owns the touch for dragging and tap-to-position,
 * so we cannot wrap it in `detectTapGestures` (that would swallow drags). Instead we observe
 * pointer-downs on the [PointerEventPass.Initial] pass *without consuming them*, so the Slider
 * still receives every event and drags / single taps behave normally. Only when a second down
 * lands within the platform double-tap timeout do we consume that one gesture and fire the reset —
 * consuming it stops the Slider from also moving the thumb to the tapped position.
 *
 * **Binding contract.** Like iOS, route [value] through a stable state holder (a ViewModel
 * StateFlow or `remember`ed state). [onReset] should write [defaultValue] back through the same
 * channel so the reset survives the Slider's own value write-back.
 */
@Composable
fun ResettableSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    defaultValue: Float,
    onReset: () -> Unit,
    modifier: Modifier = Modifier,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
    enabled: Boolean = true,
    onValueChangeFinished: (() -> Unit)? = null,
) {
    val tickColor = MaterialTheme.colorScheme.onSurfaceVariant
    Box(modifier) {
        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = valueRange,
            enabled = enabled,
            onValueChangeFinished = onValueChangeFinished,
            modifier = Modifier
                .fillMaxWidth()
                .defaultTick(
                    fraction = defaultFraction(value = defaultValue, range = valueRange),
                    color = tickColor,
                    enabled = enabled,
                )
                .doubleTapReset(enabled = enabled, onDoubleTap = onReset),
        )
    }
}

/** Position of [value] within [range], clamped to 0..1. */
private fun defaultFraction(value: Float, range: ClosedFloatingPointRange<Float>): Float {
    val span = range.endInclusive - range.start
    if (span <= 0f) return 0f
    return ((value - range.start) / span).coerceIn(0f, 1f)
}

/**
 * Half the Material3 Slider thumb width — the thumb centre (which marks the value) travels from this
 * inset on the left to `width - inset` on the right. Material3 1.3's slider thumb is 4dp wide, so the
 * inset is 2dp. Using the wrong value skews the tick toward the centre, worst at the extremes (the
 * error is `(usedInset - realInset)·(1 - 2·fraction)`, which is zero at fraction 0.5).
 */
private val ThumbHalfWidth: Dp = 2.dp

/**
 * Draws a small vertical tick at [fraction] of the thumb's travel range, so it lines up with where
 * the thumb centre sits at that value.
 */
private fun Modifier.defaultTick(fraction: Float, color: androidx.compose.ui.graphics.Color, enabled: Boolean): Modifier =
    drawWithContent {
        drawContent()
        val inset = ThumbHalfWidth.toPx()
        val usable = (size.width - inset * 2).coerceAtLeast(0f)
        val x = inset + usable * fraction
        val tickHeight = 8.dp.toPx()
        val tickWidth = 2.dp.toPx()
        drawRect(
            color = color.copy(alpha = if (enabled) 0.55f else 0.25f),
            topLeft = Offset(x - tickWidth / 2f, (size.height - tickHeight) / 2f),
            size = Size(tickWidth, tickHeight),
        )
    }

/**
 * Fires [onDoubleTap] when two pointer-downs land within the platform double-tap timeout, without
 * interfering with the Slider's own drag / tap handling. Events are inspected on the Initial pass
 * and left unconsumed, so the Slider sees them all; only the confirmed double-tap gesture is
 * consumed (so the Slider doesn't also jump the thumb to the tap location).
 */
private fun Modifier.doubleTapReset(enabled: Boolean, onDoubleTap: () -> Unit): Modifier =
    if (!enabled) {
        this
    } else {
        pointerInput(Unit) {
            val timeout = viewConfiguration.doubleTapTimeoutMillis
            var lastDownUptime = 0L
            awaitEachGesture {
                // requireUnconsumed = false + Initial pass: we observe the down before the Slider
                // acts on it, but do not consume it unless this is the second tap of a double-tap.
                val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                val now = down.uptimeMillis
                val isDoubleTap = lastDownUptime != 0L && (now - lastDownUptime) <= timeout
                lastDownUptime = now
                if (isDoubleTap) {
                    // Reset so a triple-tap doesn't fire twice.
                    lastDownUptime = 0L
                    down.consume()
                    onDoubleTap()
                    // Swallow the remainder of this gesture so the Slider ignores it entirely.
                    var stillPressed = true
                    while (stillPressed) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        event.changes.forEach { it.consume() }
                        stillPressed = event.changes.any { it.pressed }
                    }
                }
            }
        }
    }
