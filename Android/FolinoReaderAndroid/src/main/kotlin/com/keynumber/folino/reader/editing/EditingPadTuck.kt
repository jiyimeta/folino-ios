package com.keynumber.folino.reader.editing

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.calculateTargetValue
import androidx.compose.animation.core.spring
import androidx.compose.animation.splineBasedDecay
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.keynumber.folino.editor.PadTuckGeometry
import com.keynumber.folino.editor.PadTuckSide
import com.keynumber.folino.reader.R
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

/**
 * How much of the tucked CARD stays on screen. This is the one number the two platforms deliberately disagree on
 * (see `EditorPadTuckGeometry`'s type doc): iOS parks the card entirely offscreen and leaves a separate chevron
 * pull tab, Android leaves this sliver of the pad itself and adds no handle — each imitates its own OS's PiP
 * dismissal, and on Android the stashed window IS its own grab point. 24.dp is enough card to read as "the pad is
 * parked here" and to land a finger on, without shading the score's margin content.
 */
internal val PAD_TUCK_PEEK: Dp = 24.dp

/**
 * The card's breathing room off the screen edges — the Android spelling of `EditorPadView.horizontalMargin`. It
 * must equal the horizontal padding the caller wraps the pad card in, and that padding must ride INSIDE
 * [EditingPadTuck]'s `content` (the padded card is what gets passed in), because the tuck geometry subtracts this
 * from the measured frame so the CARD — the visible thing — is what parks flush against the edge: with the padding
 * outside the wrapper instead, the measured frame is the bare card, the park stops a margin short, and the "sliver"
 * grows by a margin-wide strip of empty frame. iOS learned the same lesson the same way (`restOffsetX`'s doc).
 */
internal val PAD_TUCK_HORIZONTAL_MARGIN: Dp = 8.dp

/** The one spring for everything that is not the finger — tuck, restore, and both spring-backs — mirroring iOS's
 * single `tuckSpring` (`spring(duration: 0.4, bounce: 0.2)`). One curve so every settle reads as the same motion. */
private val TUCK_SPRING = spring<Float>(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow)

/**
 * The PiP-style side tuck around the note-input pad: drag the card far enough toward a side edge and it parks past
 * that edge with [PAD_TUCK_PEEK] of it still showing; drag or tap the sliver to bring it back. This is what replaced
 * the app-bar visibility toggle on both platforms — dismissal became PiP's, not a toolbar button's.
 *
 * [isExpanded] and [tuckSide] are the caller's PERSISTED state, and they seed this wrapper's own — which is what
 * the motion and every release decision then read. A release moves that local state, starts the spring, and
 * reports outward through [onTuck] / [onRestore]; the caller's write comes back later and agrees. The mirror is a
 * lead, not a fork: whenever the parameters themselves move — the restore at launch, or any other writer — they
 * win. See `expandedNow` for the release this ordering protects.
 *
 * Every threshold and release decision comes from the shared Swift geometry through [geometry] — asked at a
 * gesture's start and end only, never per frame (see [PadTuckGeometry]'s own doc for why); between the two, the
 * offset is a cached base plus the finger's translation. What Compose has to add is the projected travel: iOS
 * judges releases on UIKit's `predictedEndTranslation`, and the equivalent here is the release velocity run through
 * [splineBasedDecay] — the same "where would this flick have ended up" number, so a flick commits a tuck without
 * the finger covering the whole distance.
 *
 * Horizontal only: this port does not carry iOS's top/bottom dock, so the finger's y never moves the pad — it still
 * feeds the geometry, whose second tuck guard reads the velocity's DIRECTION to tell a sideways flick from a
 * vertical one drifting sideways. And the sides are PHYSICAL screen edges in every layout direction:
 * [PadTuckSide.LEADING] is the left edge, [PadTuckSide.TRAILING] the right, because the shared geometry's sign
 * convention is gesture space (+x = rightward = TRAILING) and gesture deltas are never RTL-mirrored — which is why
 * the offset goes through [absoluteOffset]; the RTL-aware `offset {}` would mirror the park under RTL while the
 * drag stayed physical, and the card would sail off the wrong edge.
 *
 * The caller lays the wrapper out horizontally centered in the viewport it reports (the rest offset is measured
 * from the centered position), passes the pad card — already wrapped in its [PAD_TUCK_HORIZONTAL_MARGIN] padding,
 * see that constant — as [content], and gets the frame's measured height back through [onCardHeightChange] to pad
 * the score's scroll content by; whether a tucked pad reserves that room is the caller's decision, not measured
 * differently here.
 */
// PARITY(android): note pad vertical dock — iOS's same drag also moves the pad between a TOP and a bottom dock
//   (`EditorPadPlacement`, persisted as `editorPadPlacement`), so a reader working at the bottom of a system can
//   park the keys above the music instead of under it. Android tucks sideways only. Adding it means a second axis
//   on this gesture, a top-docked placement for the card, and the scroll-inset rule iOS settled on (a top dock
//   reserves nothing, or the score visibly jumps down as the pad arrives).
@Composable
fun EditingPadTuck(
    isExpanded: Boolean,
    tuckSide: PadTuckSide,
    geometry: PadTuckGeometry,
    viewportWidthPx: Float,
    viewportHeightPx: Float,
    onTuck: (PadTuckSide) -> Unit,
    onRestore: () -> Unit,
    onCardHeightChange: (Dp) -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val marginPx = with(density) { PAD_TUCK_HORIZONTAL_MARGIN.toPx() }
    val peekPx = with(density) { PAD_TUCK_PEEK.toPx() }
    val decay = remember(density) { splineBasedDecay<Float>(density) }

    // The pad's horizontal offset from its centered layout position — the ONE value everything moves through, so a
    // drag taking over from a running settle is a snap of this animatable, not a second source of truth to reconcile.
    val offsetX = remember { Animatable(0f) }

    // **Local state is the truth; the hoisted preference is the echo.** A release writes these two immediately and
    // only then reports through [onTuck] / [onRestore], because the caller persists to DataStore and a release must
    // neither wait on that round trip nor be re-judged against a value that has not caught up yet: a tuck-flick
    // followed straight away by a pull on the sliver would otherwise be judged as an EXPANDED pad's release and
    // park the card on the opposite edge instead of restoring it. iOS splits the same way and says so — its
    // `EditorChromeView` drives the layout from `@State` mirrors of its `@AppStorage` pair, because reading the
    // stored value back made re-docking lurch.
    var expandedNow by remember { mutableStateOf(isExpanded) }
    var sideNow by remember { mutableStateOf(tuckSide) }
    // The caller still wins whenever IT moves — the restore at launch, or anything else that writes the
    // preference — so the mirrors are a lead, not a fork.
    LaunchedEffect(isExpanded, tuckSide) {
        expandedNow = isExpanded
        sideNow = tuckSide
    }

    // The drag detector lives in a `pointerInput(Unit)` that never restarts: keying it on the state it reads would
    // tear the detector down at the exact moment a release changes that state, aborting the gesture mid-decision —
    // the same class of bug as the cancelled-drag stranding below. So everything the detector reads at release time
    // comes through `rememberUpdatedState` instead of the (stale-once-captured) closure.
    val currentExpanded by rememberUpdatedState(expandedNow)
    val currentSide by rememberUpdatedState(sideNow)
    val currentGeometry by rememberUpdatedState(geometry)
    val currentViewportWidth by rememberUpdatedState(viewportWidthPx)
    val currentViewportHeight by rememberUpdatedState(viewportHeightPx)
    val currentOnTuck by rememberUpdatedState(onTuck)
    val currentOnRestore by rememberUpdatedState(onRestore)

    var frameWidthPx by remember { mutableFloatStateOf(0f) }
    var isDragging by remember { mutableStateOf(false) }
    // Whether the pad has ever been placed at a real rest. Until then it is held invisible (see the graphicsLayer):
    // a pad restored at launch sits fine at zero, but a pad restored TUCKED has no computable park before the first
    // measurement, and animating to it from zero would flash the card sliding across the whole score.
    var hasSettled by remember { mutableStateOf(false) }

    // Where the pad rests for a given state — the only two geometry answers that position anything. Reads the
    // updated-state holders so the release handler (whose closure never refreshes) gets live values too.
    fun restOffset(expanded: Boolean, side: PadTuckSide): Float = if (expanded) {
        0f
    } else {
        currentGeometry.restOffsetXPx(side, currentViewportWidth, frameWidthPx, marginPx, peekPx)
    }

    fun settle(target: Float) {
        scope.launch { offsetX.animateTo(target, TUCK_SPRING) }
    }

    // The only two ways the resting state changes, whichever asked — a drag's release, a tap on the sliver, an
    // accessibility action. Each writes the local truth, starts the motion, and only then reports outward, so no
    // path can end up judging its successor against a preference that is still being written.
    fun requestTuck(side: PadTuckSide) {
        expandedNow = false
        sideNow = side
        settle(restOffset(expanded = false, side = side))
        currentOnTuck(side)
    }

    fun requestRestore() {
        expandedNow = true
        settle(0f)
        currentOnRestore()
    }

    // Whatever moved the pad's resting state — a release below, an accessibility action, the caller restoring the
    // preference at launch — the pad animates to that state's rest. A release also settles locally with the same
    // target, so the motion starts on the release frame; this effect then retargets the running spring, which
    // continues from its live value and velocity. Skipped mid-drag — the finger outranks everything.
    LaunchedEffect(expandedNow, sideNow, viewportWidthPx, frameWidthPx) {
        if (frameWidthPx == 0f || isDragging) return@LaunchedEffect
        val target = restOffset(expandedNow, sideNow)
        if (hasSettled) {
            offsetX.animateTo(target, TUCK_SPRING)
        } else {
            // The first placement is a fact, not a transition — there is no previous rest to animate from.
            offsetX.snapTo(target)
            hasSettled = true
        }
    }

    val hideLabel = stringResource(R.string.reader_editing_pad_hide)
    val showLabel = stringResource(R.string.reader_editing_pad_show)
    val padLabel = stringResource(R.string.reader_editing_pad)
    val semanticsModifier = if (expandedNow) {
        // The non-gestural equivalent of the tuck drag, parked toward the side the pad last tucked to so the sliver
        // comes back where the user left it. No contentDescription while expanded: naming the container would give
        // TalkBack a labeled node wrapping every key and fight the keys' own traversal — the action is enough.
        Modifier.semantics {
            customActions = listOf(
                CustomAccessibilityAction(hideLabel) {
                    requestTuck(sideNow)
                    true
                },
            )
        }
    } else {
        // TalkBack's copy of the structural rule below: while tucked the keys' nodes are wiped, not just obscured,
        // and the sliver is one plain "Note pad" element whose activation — and labeled action — restores.
        Modifier.clearAndSetSemantics {
            contentDescription = padLabel
            onClick {
                requestRestore()
                true
            }
            customActions = listOf(
                CustomAccessibilityAction(showLabel) {
                    requestRestore()
                    true
                },
            )
        }
    }

    Box(
        modifier
            .graphicsLayer { alpha = if (!currentExpanded && !hasSettled) 0f else 1f }
            // `absoluteOffset`, not `offset` — see the class doc: the geometry's signs are physical screen
            // directions, and `offset {}` would mirror them under RTL while the drag deltas stayed unmirrored.
            .absoluteOffset { IntOffset(offsetX.value.roundToInt(), 0) }
            .onSizeChanged { size ->
                frameWidthPx = size.width.toFloat()
                onCardHeightChange(with(density) { size.height.toDp() })
            }
            // After `absoluteOffset` in the chain, so the touch region rides the pad instead of staying at the
            // centered layout slot the pad has been moved out of.
            .pointerInput(Unit) {
                // Cached per gesture: the offset a drag frame applies is this base plus the finger's translation —
                // arithmetic only, no geometry call, per the interface's start/end-only contract.
                var dragBase = 0f
                var translation = Offset.Zero
                val tracker = VelocityTracker()
                detectDragGestures(
                    onDragStart = {
                        // A drag that starts mid-animation takes over from wherever the spring has the pad NOW:
                        // the base is the live animated value, and stopping the spring keeps it from moving the
                        // base out from under the first drag frame.
                        dragBase = offsetX.value
                        translation = Offset.Zero
                        tracker.resetTracking()
                        isDragging = true
                        scope.launch { offsetX.stop() }
                    },
                    onDrag = { change, dragAmount ->
                        // Consuming is what cancels a key press the drag started on — the down reached the key,
                        // but a consumed move past slop withdraws it, so dragging anywhere on the card moves the
                        // pad while a plain tap still lands on the key underneath.
                        change.consume()
                        translation += dragAmount
                        // The tracker is fed the ACCUMULATED translation, not `change.position`: positions are
                        // local to this node, which this very gesture is moving, so a stationary finger over a
                        // moving pad reads as motion. Deltas are computed within one event dispatch — both ends
                        // in the same frame — so their sum is immune to the node having moved between frames.
                        // (Same feedback loop iOS dodged by measuring its DragGesture in the global space.)
                        tracker.addPosition(change.uptimeMillis, translation)
                        // Horizontal only — the y translation is tracked for the release velocity but never moves
                        // the pad; this port carries no top/bottom dock.
                        scope.launch { offsetX.snapTo(dragBase + translation.x) }
                    },
                    onDragEnd = {
                        isDragging = false
                        val velocity = tracker.calculateVelocity()
                        // Compose's stand-in for UIKit's `predictedEndTranslation`: run the release velocity
                        // through the platform fling decay and take where the translation would have coasted to.
                        val projectedX = decay.calculateTargetValue(translation.x, velocity.x)
                        val threshold = currentGeometry.threshold(currentViewportWidth, currentViewportHeight)
                        if (currentExpanded) {
                            val side = currentGeometry.tuckDestination(
                                translation.x,
                                projectedX,
                                velocity.x,
                                velocity.y,
                                threshold,
                            )
                            if (side != null) {
                                requestTuck(side)
                            } else {
                                // A reposition, not a dismissal — nothing changes but the offset going home.
                                settle(0f)
                            }
                        } else {
                            if (currentGeometry.restoresFromTuck(currentSide, projectedX, threshold)) {
                                requestRestore()
                            } else {
                                settle(restOffset(expanded = false, side = currentSide))
                            }
                        }
                    },
                    onDragCancel = {
                        // A cancelled drag never reaches onDragEnd, so nothing above runs — without this the pad
                        // stayed stranded wherever the last frame put it (the bug iOS's `padBranch` catches with
                        // its translation-sprang-back-to-zero watch). No decision to make: back to the rest the
                        // current state already describes.
                        isDragging = false
                        settle(restOffset(currentExpanded, currentSide))
                    },
                )
            }
            .then(semanticsModifier),
    ) {
        content()
        if (!expandedNow) {
            // What makes the tucked keys inert STRUCTURALLY: this sibling sits on top of the card, so hit testing
            // resolves here and the keys under the sliver never see the down at all — no per-key enabled flag to
            // keep honest. A tap restores; a slide is the parent's drag (the tap detector holds the down without
            // consuming it and abandons once the drag consumes past slop, the same handoff the keys make).
            Box(
                Modifier
                    .matchParentSize()
                    .pointerInput(Unit) {
                        detectTapGestures { requestRestore() }
                    },
            )
        }
    }
}
