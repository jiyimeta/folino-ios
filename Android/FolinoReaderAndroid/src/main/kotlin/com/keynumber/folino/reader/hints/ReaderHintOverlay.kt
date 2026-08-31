package com.keynumber.folino.reader.hints

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/**
 * Reports this control's window frame as `target`'s anchor, so a hint pointing at it knows where to put its caret.
 *
 * Window coordinates, and in dp: the shared `ReaderHintBubbleLayout` states its margins in dp/pt, and window space is
 * the one frame of reference both the anchors and the overlay can be measured in. (iOS reaches for window frames for
 * the same reason its own `.global` space could not be trusted across hosting contexts.)
 *
 * `active = false` withdraws the anchor instead — which also withdraws the hint, since the engine only ever offers a
 * hint for a control that has reported itself. That is how the transport's two hints stay mutually exclusive: each
 * state anchors its own target and clears the other's.
 */
@Composable
fun Modifier.readerHintAnchor(target: ReaderHintTarget, active: Boolean = true): Modifier {
    val density = LocalDensity.current
    DisposableEffect(target, active) {
        if (!active) ReaderHintController.clearAnchor(target)
        onDispose { ReaderHintController.clearAnchor(target) }
    }
    if (!active) return this
    return onGloballyPositioned { coordinates ->
        val bounds = coordinates.boundsInWindow()
        ReaderHintController.setAnchor(target, bounds.toAnchor(density))
    }
}

private fun Rect.toAnchor(density: Density): ReaderHintAnchor = with(density) {
    ReaderHintAnchor(
        x = left.toDp().value.toDouble(),
        y = top.toDp().value.toDouble(),
        width = width.toDp().value.toDouble(),
        height = height.toDp().value.toDouble(),
    )
}

/**
 * Dismisses the showing hint on any touch anywhere, WITHOUT consuming it.
 *
 * Attach to the Reader's root — a parent, never a sibling overlay. A full-screen sibling would swallow the tap, and
 * the whole point is that the tap that gets rid of the bubble still reaches whatever it landed on. Observing in the
 * `Initial` pass and never calling `consume()` is Compose's reading of iOS's window-level recognizer with
 * `cancelsTouchesInView = false`.
 *
 * **The node is installed unconditionally, and [showing] is read from inside it.** Gating the modifier itself —
 * `if (!showing) this else pointerInput { … }` — changes the modifier chain the instant the first touch dismisses
 * the bubble, and Compose resets pointer input for the subtree when that happens, cancelling the gesture *in
 * flight*. The visible symptom was the worst one available: the transport coach mark teaches a swipe, and the first
 * swipe after it appeared did nothing, because the down event that dismissed the bubble also tore down the node the
 * swipe was being tracked by. `pointerInput(Unit)` plus `rememberUpdatedState` keeps one stable node for the
 * lifetime of the Reader and lets the condition move underneath it.
 */
@Composable
fun Modifier.readerHintDismissOnTap(showing: Boolean): Modifier {
    val isShowing = rememberUpdatedState(showing)
    return pointerInput(Unit) {
        awaitPointerEventScope {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                if (event.type == PointerEventType.Press && isShowing.value) {
                    ReaderHintController.dismiss()
                }
            }
        }
    }
}

/**
 * Runs the delays the engine asked for. A token that changes restarts the wait; a token of zero cancels it.
 *
 * The engine deliberately does not sleep — it says what to offer and how long from now, and re-checks every
 * precondition when [ReaderHintController.fireDeferredOffer] calls back, so a timer that outlives its reason is a
 * no-op rather than a stray bubble.
 */
@Composable
fun ReaderHintDeferredOffers(state: ReaderHintState) {
    DeferredOffer(state.transportExpandSchedule, state.deferredOfferDelayMillis, ReaderHintDeferredOffer.TRANSPORT_EXPAND)
    DeferredOffer(state.padRestoreSchedule, state.deferredOfferDelayMillis, ReaderHintDeferredOffer.PAD_RESTORE)
    DeferredOffer(state.padMoveSchedule, state.deferredOfferDelayMillis, ReaderHintDeferredOffer.PAD_MOVE)
}

@Composable
private fun DeferredOffer(token: Int, delayMillis: Long, offer: ReaderHintDeferredOffer) {
    LaunchedEffect(token) {
        if (token == 0) return@LaunchedEffect
        delay(delayMillis)
        ReaderHintController.fireDeferredOffer(offer)
    }
}

/**
 * The bubble itself, placed against its anchor.
 *
 * Fills the Reader's root so it can measure its own window origin the same way the anchors were measured — both ends
 * of the subtraction below are then stated in one space by construction, which is the bug this shape exists to
 * prevent. Where the card actually lands is [ReaderHintController.bubbleFrame]'s answer, i.e. the shared
 * `ReaderHintBubbleLayout`; nothing here re-derives it.
 */
@Composable
fun ReaderHintOverlay(state: ReaderHintState, onActivate: (ReaderFeatureHint) -> Unit) {
    val density = LocalDensity.current
    val metrics = ReaderHintController.metrics
    var overlayOrigin by remember { mutableStateOf(Offset.Zero) }

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .onGloballyPositioned { overlayOrigin = it.positionInWindow() },
    ) {
        val viewportWidth = maxWidth.value.toDouble()
        val viewportHeight = maxHeight.value.toDouble()

        val live: Pair<ReaderFeatureHint, ReaderHintBubbleFrame>? =
            state.hint?.let { hint ->
                state.anchor?.let { anchor ->
                    hint to ReaderHintController.bubbleFrame(
                        target = hint.target,
                        anchor = with(density) {
                            anchor.copy(
                                x = anchor.x - overlayOrigin.x.toDp().value,
                                y = anchor.y - overlayOrigin.y.toDp().value,
                            )
                        },
                        viewportWidth = viewportWidth,
                        viewportHeight = viewportHeight,
                    )
                }
            }

        // The exit transition outlives the state that produced it, so the last live pair is what keeps drawing while
        // the bubble fades out.
        var shown by remember { mutableStateOf(live) }
        if (live != null) shown = live
        val (hint, frame) = shown ?: return@BoxWithConstraints

        val transformOrigin = TransformOrigin(0.5f, if (frame.below) 0f else 1f)
        AnimatedVisibility(
            visible = live != null,
            modifier = Modifier.align(if (frame.below) Alignment.TopStart else Alignment.BottomStart),
            enter = fadeIn(tween(metrics.transitionDurationMillis)) + scaleIn(
                animationSpec = tween(metrics.transitionDurationMillis),
                initialScale = metrics.transitionScale.toFloat(),
                transformOrigin = transformOrigin,
            ),
            exit = fadeOut(tween(metrics.transitionDurationMillis)) + scaleOut(
                animationSpec = tween(metrics.transitionDurationMillis),
                targetScale = metrics.transitionScale.toFloat(),
                transformOrigin = transformOrigin,
            ),
        ) {
            Box(
                Modifier
                    .offset {
                        val x = with(density) { frame.originX.dp.toPx() }.roundToInt()
                        val edge = with(density) { frame.edgeY.dp.toPx() }.roundToInt()
                        // Below its control the card hangs from `edgeY`; above it, `edgeY` is the card's BOTTOM, and
                        // the box is bottom-aligned, so the offset is stated relative to the container's own bottom.
                        val containerHeight = with(density) { maxHeight.toPx() }.roundToInt()
                        IntOffset(x, if (frame.below) edge else edge - containerHeight)
                    }
                    .width(frame.width.dp),
            ) {
                ReaderHintBubble(hint, frame) { onActivate(hint) }
            }
        }
    }
}

@Composable
private fun ReaderHintBubble(
    hint: ReaderFeatureHint,
    frame: ReaderHintBubbleFrame,
    onActivate: () -> Unit,
) {
    val density = LocalDensity.current
    val metrics = ReaderHintController.metrics
    val isTablet = LocalConfiguration.current.smallestScreenWidthDp >= TABLET_SMALLEST_WIDTH_DP
    val shape = remember(frame.below, frame.caretDX, density) {
        ReaderHintBubbleShape(caretUp = frame.below, caretDX = frame.caretDX)
    }

    Column(
        Modifier
            // Card and caret are ONE shape, so a single shadow wraps the whole silhouette with no seam where the
            // arrow meets the body — the same reason iOS traces them as one path.
            .shadow(BUBBLE_ELEVATION, shape, clip = false)
            .background(MaterialTheme.colorScheme.surfaceContainerHigh, shape)
            .border(HAIRLINE, MaterialTheme.colorScheme.outlineVariant.copy(alpha = BORDER_ALPHA), shape)
            .clickable(onClick = onActivate)
            .padding(
                PaddingValues(
                    start = metrics.horizontalPadding.dp,
                    end = metrics.horizontalPadding.dp,
                    // Reserve the caret strip on the protruding side so text never overlaps the arrow.
                    top = metrics.verticalPadding.dp + if (frame.below) metrics.caretHeight.dp else 0.dp,
                    bottom = metrics.verticalPadding.dp + if (frame.below) 0.dp else metrics.caretHeight.dp,
                ),
            ),
        verticalArrangement = Arrangement.spacedBy(metrics.titleMessageSpacing.dp),
    ) {
        Text(
            text = stringResource(hint.titleRes),
            style = MaterialTheme.typography.titleSmall,
            fontSize = metrics.titleFontSize.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.primary,
        )
        Text(
            text = stringResource(hint.messageRes(isTablet)),
            style = MaterialTheme.typography.bodySmall,
            fontSize = metrics.messageFontSize.sp,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

/**
 * A rounded-rectangle card with a triangular caret on one edge, unioned into ONE outline so fill, border and shadow
 * treat card and arrow as a single component.
 *
 * [caretUp] puts the arrow on the top edge (card below its control); otherwise the bottom edge. [caretDX] shifts the
 * arrow off-center so it keeps pointing at the control when the card has been clamped to a screen edge — the shared
 * layout has already bounded it so the apex can never grow out of a rounded corner.
 */
private data class ReaderHintBubbleShape(val caretUp: Boolean, val caretDX: Double) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val metrics = ReaderHintController.metrics
        val caretHeight = with(density) { metrics.caretHeight.dp.toPx() }
        val halfCaret = with(density) { (metrics.caretWidth / 2).dp.toPx() }
        val radius = with(density) { metrics.cornerRadius.dp.toPx() }
        val apexX = size.width / 2 + with(density) { caretDX.dp.toPx() }

        val bodyTop = if (caretUp) caretHeight else 0f
        val bodyBottom = if (caretUp) size.height else size.height - caretHeight
        val body = Path().apply {
            addRoundRect(
                androidx.compose.ui.geometry.RoundRect(
                    left = 0f, top = bodyTop, right = size.width, bottom = bodyBottom,
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius, radius),
                ),
            )
        }
        val caret = Path().apply {
            if (caretUp) {
                moveTo(apexX - halfCaret, bodyTop)
                lineTo(apexX, 0f)
                lineTo(apexX + halfCaret, bodyTop)
            } else {
                moveTo(apexX + halfCaret, bodyBottom)
                lineTo(apexX, size.height)
                lineTo(apexX - halfCaret, bodyBottom)
            }
            close()
        }
        return Outline.Generic(Path().apply { op(body, caret, PathOperation.Union) })
    }
}

/** Material's own breakpoint for "this is a tablet", which is what decides whether a stylus is worth naming. */
private const val TABLET_SMALLEST_WIDTH_DP = 600

private val BUBBLE_ELEVATION = 8.dp
private val HAIRLINE = 0.5.dp
private const val BORDER_ALPHA = 0.6f
