package com.keynumber.folino.reader.editing

import android.graphics.Rect
import android.os.Build
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.calculateTargetValue
import androidx.compose.animation.core.spring
import androidx.compose.animation.splineBasedDecay
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
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
import com.keynumber.folino.editor.PadPlacement
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

/** The one spring for everything that is not the finger — tuck, restore, dock, and every spring-back — mirroring
 * iOS's single `tuckSpring` (`spring(duration: 0.4, bounce: 0.2)`). One curve so every settle reads as the same
 * motion. */
private val TUCK_SPRING = spring<Float>(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow)

/**
 * The note-input pad's placement layer: the PiP-style side tuck and the top / bottom dock, both driven by one
 * drag. Pull the card far enough toward a side edge and it parks past that edge with [PAD_TUCK_PEEK] of it still
 * showing; drag or tap the sliver to bring it back. Drag it up or down and it re-docks to the nearer end of the
 * score, so the keys can get out of the way of the bar you are writing. This is what replaced the app-bar
 * visibility toggle on both platforms — dismissal became PiP's, not a toolbar button's.
 *
 * [isExpanded], [tuckSide] and [placement] are the caller's PERSISTED state, and they seed this wrapper's own —
 * which is what the motion and every release decision then read. A release moves that local state, starts the
 * spring, and reports outward through [onTuck] / [onRestore] / [onDock]; the caller's write comes back later and
 * agrees. The mirror is a lead, not a fork: whenever the parameters themselves move — the restore at launch, or
 * any other writer — they win. See `expandedNow` for the release this ordering protects.
 *
 * Every threshold and release decision comes from the shared Swift geometry through [geometry] — asked at a
 * gesture's start and end only, never per frame (see [PadTuckGeometry]'s own doc for why); between the two, the
 * offset is a cached base plus the finger's translation. What Compose has to add is the projected travel: iOS
 * judges releases on UIKit's `predictedEndTranslation`, and the equivalent here is the release velocity run through
 * [splineBasedDecay] — the same "where would this flick have ended up" number, so a flick commits without the
 * finger covering the whole distance.
 *
 * **The pad is positioned entirely by offset, never by layout alignment.** It sits at the parent's top-start and
 * both axes are one `Animatable` each, so a dock change is the same continuous motion a tuck is; flipping a
 * `Modifier.align` instead would teleport the card a screen-height before the spring could start. iOS reaches the
 * same shape from the other side — one shared offset for every pad motion that is not the finger.
 *
 * The side edges are PHYSICAL in every layout direction: [PadTuckSide.LEADING] is the left edge,
 * [PadTuckSide.TRAILING] the right, because the shared geometry's sign convention is gesture space
 * (+x = rightward = TRAILING) and gesture deltas are never RTL-mirrored — which is why the offset goes through
 * [absoluteOffset]; the RTL-aware `offset {}` would mirror the park under RTL while the drag stayed physical, and
 * the card would sail off the wrong edge.
 *
 * [bottomInset] and [topInset] are what the pad parks clear of at each dock — the compact transport's band at the
 * bottom, the app bar's own breathing room at the top. They position the pad; they are deliberately NOT part of
 * the dock DECISION, which measures against the raw viewport so the same gesture answers the same on both
 * platforms (`EditorPadTuckGeometry.parkedCenterY`).
 *
 * The caller passes the pad card — already wrapped in its [PAD_TUCK_HORIZONTAL_MARGIN] padding, see that
 * constant — as [content], and gets the frame's measured height back through [onCardHeightChange] to pad the
 * score's scroll content by; whether a tucked or top-docked pad reserves that room is the caller's decision.
 */
@Composable
fun BoxScope.EditingPadTuck(
    isExpanded: Boolean,
    tuckSide: PadTuckSide,
    placement: PadPlacement,
    geometry: PadTuckGeometry,
    viewportWidthPx: Float,
    viewportHeightPx: Float,
    bottomInset: Dp,
    topInset: Dp,
    onTuck: (PadTuckSide) -> Unit,
    onRestore: () -> Unit,
    onDock: (PadPlacement) -> Unit,
    onCardHeightChange: (Dp) -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val marginPx = with(density) { PAD_TUCK_HORIZONTAL_MARGIN.toPx() }
    val peekPx = with(density) { PAD_TUCK_PEEK.toPx() }
    val bottomInsetPx = with(density) { bottomInset.toPx() }
    val topInsetPx = with(density) { topInset.toPx() }
    val decay = remember(density) { splineBasedDecay<Float>(density) }

    // The pad's offset from the parent's top-start — the ONE pair of values everything moves through, so a drag
    // taking over from a running settle is a snap of these animatables, not a second source of truth to reconcile.
    val offsetX = remember { Animatable(0f) }
    val offsetY = remember { Animatable(0f) }

    // **Local state is the truth; the hoisted preference is the echo.** A release writes these three immediately
    // and only then reports outward, because the caller persists to DataStore and a release must neither wait on
    // that round trip nor be re-judged against a value that has not caught up yet: a tuck-flick followed straight
    // away by a pull on the sliver would otherwise be judged as an EXPANDED pad's release and park the card on the
    // opposite edge instead of restoring it. iOS splits the same way and says so — its `EditorChromeView` drives
    // the layout from `@State` mirrors of its `@AppStorage` values, because reading the stored value back made
    // re-docking lurch.
    var expandedNow by remember { mutableStateOf(isExpanded) }
    var sideNow by remember { mutableStateOf(tuckSide) }
    var placementNow by remember { mutableStateOf(placement) }
    // The caller still wins whenever IT moves — the restore at launch, or anything else that writes the
    // preference — so the mirrors are a lead, not a fork.
    LaunchedEffect(isExpanded, tuckSide, placement) {
        expandedNow = isExpanded
        sideNow = tuckSide
        placementNow = placement
    }

    // The drag detector lives in a `pointerInput(Unit)` that never restarts: keying it on the state it reads would
    // tear the detector down at the exact moment a release changes that state, aborting the gesture mid-decision —
    // the same class of bug as the cancelled-drag stranding below. So everything the detector reads at release time
    // comes through `rememberUpdatedState` instead of the (stale-once-captured) closure.
    val currentExpanded by rememberUpdatedState(expandedNow)
    val currentSide by rememberUpdatedState(sideNow)
    val currentPlacement by rememberUpdatedState(placementNow)
    val currentGeometry by rememberUpdatedState(geometry)
    val currentViewportWidth by rememberUpdatedState(viewportWidthPx)
    val currentViewportHeight by rememberUpdatedState(viewportHeightPx)
    val currentBottomInsetPx by rememberUpdatedState(bottomInsetPx)
    val currentTopInsetPx by rememberUpdatedState(topInsetPx)
    val currentOnTuck by rememberUpdatedState(onTuck)
    val currentOnRestore by rememberUpdatedState(onRestore)
    val currentOnDock by rememberUpdatedState(onDock)

    var frameWidthPx by remember { mutableFloatStateOf(0f) }
    var frameHeightPx by remember { mutableFloatStateOf(0f) }
    var isDragging by remember { mutableStateOf(false) }
    // Whether the pad has ever been placed at a real rest. Until then it is held invisible (see the graphicsLayer):
    // its resting offset is not computable before the first measurement, and animating to it from the top-start
    // corner would flash the card across the whole score.
    var hasSettled by remember { mutableStateOf(false) }

    // Where the pad rests for a given state — the only geometry answers that position anything. Reads the
    // updated-state holders so the release handler (whose closure never refreshes) gets live values too.
    fun restOffsetX(expanded: Boolean, side: PadTuckSide): Float = if (expanded) {
        0f
    } else {
        currentGeometry.restOffsetXPx(side, currentViewportWidth, frameWidthPx, marginPx, peekPx)
    }

    fun restOffsetY(dock: PadPlacement): Float = if (dock == PadPlacement.BOTTOM) {
        currentViewportHeight - currentBottomInsetPx - frameHeightPx
    } else {
        currentTopInsetPx
    }

    fun settle(targetX: Float, targetY: Float) {
        scope.launch { offsetX.animateTo(targetX, TUCK_SPRING) }
        scope.launch { offsetY.animateTo(targetY, TUCK_SPRING) }
    }

    // The only ways the resting state changes, whichever asked — a drag's release, a tap on the sliver, an
    // accessibility action. Each writes the local truth, starts the motion, and only then reports outward, so no
    // path can end up judging its successor against a preference that is still being written.
    fun requestTuck(side: PadTuckSide, dock: PadPlacement) {
        expandedNow = false
        sideNow = side
        placementNow = dock
        settle(restOffsetX(expanded = false, side = side), restOffsetY(dock))
        currentOnTuck(side)
        currentOnDock(dock)
    }

    fun requestRestore(dock: PadPlacement) {
        expandedNow = true
        placementNow = dock
        settle(0f, restOffsetY(dock))
        currentOnRestore()
        currentOnDock(dock)
    }

    fun requestDockOnly(dock: PadPlacement) {
        placementNow = dock
        settle(restOffsetX(currentExpanded, currentSide), restOffsetY(dock))
        currentOnDock(dock)
    }

    // Whatever moved the pad's resting state — a release below, an accessibility action, the caller restoring the
    // preference at launch, a rotation — the pad animates to that state's rest. A release also settles locally with
    // the same target, so the motion starts on the release frame; this effect then retargets the running springs,
    // which continue from their live values and velocities. Skipped mid-drag — the finger outranks everything.
    LaunchedEffect(
        expandedNow, sideNow, placementNow, viewportWidthPx, viewportHeightPx,
        frameWidthPx, frameHeightPx, bottomInsetPx, topInsetPx,
    ) {
        if (frameWidthPx == 0f || frameHeightPx == 0f || isDragging) return@LaunchedEffect
        val targetX = restOffsetX(expandedNow, sideNow)
        val targetY = restOffsetY(placementNow)
        if (hasSettled) {
            scope.launch { offsetX.animateTo(targetX, TUCK_SPRING) }
            offsetY.animateTo(targetY, TUCK_SPRING)
        } else {
            // The first placement is a fact, not a transition — there is no previous rest to animate from.
            offsetX.snapTo(targetX)
            offsetY.snapTo(targetY)
            hasSettled = true
        }
    }

    val hideLabel = stringResource(R.string.reader_editing_pad_hide)
    val showLabel = stringResource(R.string.reader_editing_pad_show)
    val moveLabel = stringResource(R.string.reader_editing_pad_move)
    val padLabel = stringResource(R.string.reader_editing_pad)
    val otherDock = if (placementNow == PadPlacement.BOTTOM) PadPlacement.TOP else PadPlacement.BOTTOM
    val semanticsModifier = if (expandedNow) {
        // The non-gestural equivalents of the drag's two outcomes. No contentDescription while expanded: naming the
        // container would give TalkBack a labeled node wrapping every key and fight the keys' own traversal — the
        // actions are enough.
        Modifier.semantics {
            customActions = listOf(
                CustomAccessibilityAction(hideLabel) {
                    // Parked toward the side the pad last tucked to, so the sliver comes back where it was left.
                    requestTuck(sideNow, placementNow)
                    true
                },
                CustomAccessibilityAction(moveLabel) {
                    requestDockOnly(otherDock)
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
                requestRestore(placementNow)
                true
            }
            customActions = listOf(
                CustomAccessibilityAction(showLabel) {
                    requestRestore(placementNow)
                    true
                },
            )
        }
    }

    // The pad's own bounds, kept out of the system's back-gesture zones.
    //
    // Without this the tucked sliver is unusable: it rests flush against a side edge, which is exactly where
    // gesture navigation claims the swipe, so pulling the pad back out navigated back instead. The whole pad is
    // excluded rather than only the sliver, because a drag that starts near an edge of the EXPANDED card is the
    // same gesture and loses the same way. The platform caps exclusions at 200dp per edge; a two-row pad is well
    // inside that budget. API 29+ — on 28 there is no gesture navigation to lose the swipe to.
    val view = LocalView.current
    DisposableEffect(view) {
        onDispose {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) view.systemGestureExclusionRects = emptyList()
        }
    }

    Box(
        modifier
            .align(Alignment.TopStart)
            .graphicsLayer { alpha = if (!hasSettled) 0f else 1f }
            // `absoluteOffset`, not `offset` — see the class doc: the geometry's signs are physical screen
            // directions, and `offset {}` would mirror them under RTL while the drag deltas stayed unmirrored.
            .absoluteOffset { IntOffset(offsetX.value.roundToInt(), offsetY.value.roundToInt()) }
            .onSizeChanged { size ->
                frameWidthPx = size.width.toFloat()
                frameHeightPx = size.height.toFloat()
                onCardHeightChange(with(density) { size.height.toDp() })
            }
            .onGloballyPositioned { coords ->
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return@onGloballyPositioned
                // The exclusion list is in the VIEW's own coordinates, while Compose reports window ones, so the
                // view's offset in the window comes back out. Recomputed on every placement pass — the pad moves
                // constantly, and a stale rect would protect a strip of screen the pad has left — but written
                // only when it actually changed: this fires on every frame of a drag, and the setter walks up to
                // the window manager.
                val origin = IntArray(2).also(view::getLocationInWindow)
                val bounds = coords.boundsInWindow()
                val rect = Rect(
                    (bounds.left - origin[0]).roundToInt(),
                    (bounds.top - origin[1]).roundToInt(),
                    (bounds.right - origin[0]).roundToInt(),
                    (bounds.bottom - origin[1]).roundToInt(),
                )
                // Assigning the whole list rather than adding to it is safe only because the pad is the app's one
                // exclusion; if a second one ever appears, both have to be published together.
                if (view.systemGestureExclusionRects.singleOrNull() != rect) {
                    view.systemGestureExclusionRects = listOf(rect)
                }
            }
            // After `absoluteOffset` in the chain, so the touch region rides the pad instead of staying at the
            // top-start layout slot the pad has been moved out of.
            .pointerInput(Unit) {
                // Cached per gesture: the offset a drag frame applies is this base plus the finger's translation —
                // arithmetic only, no geometry call, per the interface's start/end-only contract.
                var dragBase = Offset.Zero
                var translation = Offset.Zero
                val tracker = VelocityTracker()
                detectDragGestures(
                    onDragStart = {
                        // A drag that starts mid-animation takes over from wherever the springs have the pad NOW:
                        // the base is the live animated value, and stopping them keeps the base from moving out
                        // from under the first drag frame.
                        dragBase = Offset(offsetX.value, offsetY.value)
                        translation = Offset.Zero
                        tracker.resetTracking()
                        isDragging = true
                        scope.launch { offsetX.stop() }
                        scope.launch { offsetY.stop() }
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
                        scope.launch { offsetX.snapTo(dragBase.x + translation.x) }
                        scope.launch { offsetY.snapTo(dragBase.y + translation.y) }
                    },
                    onDragEnd = {
                        isDragging = false
                        val velocity = tracker.calculateVelocity()
                        // Compose's stand-in for UIKit's `predictedEndTranslation`: run the release velocity
                        // through the platform fling decay and take where the translation would have coasted to.
                        val projectedX = decay.calculateTargetValue(translation.x, velocity.x)
                        val projectedY = decay.calculateTargetValue(translation.y, velocity.y)
                        val threshold = currentGeometry.threshold(currentViewportWidth, currentViewportHeight)
                        // The dock re-derives on every release, tucked or not: a sliver slid along its edge has
                        // still changed which end of the score it is parked at, and pulling it out later has to
                        // land it there. iOS re-derives it on all three of its release branches for this reason.
                        val dock = currentGeometry.dock(
                            currentPlacement, currentViewportHeight, frameHeightPx, projectedY,
                        )
                        if (currentExpanded) {
                            val side = currentGeometry.tuckDestination(
                                translation.x,
                                projectedX,
                                velocity.x,
                                velocity.y,
                                threshold,
                            )
                            if (side != null) {
                                requestTuck(side, dock)
                            } else {
                                // A reposition, not a dismissal — the pad goes home, to the dock it landed nearest.
                                requestDockOnly(dock)
                            }
                        } else {
                            if (currentGeometry.restoresFromTuck(currentSide, projectedX, threshold)) {
                                requestRestore(dock)
                            } else {
                                requestDockOnly(dock)
                            }
                        }
                    },
                    onDragCancel = {
                        // A cancelled drag never reaches onDragEnd, so nothing above runs — without this the pad
                        // stayed stranded wherever the last frame put it (the bug iOS's `padBranch` catches with
                        // its translation-sprang-back-to-zero watch). No decision to make: back to the rest the
                        // current state already describes.
                        isDragging = false
                        settle(
                            restOffsetX(currentExpanded, currentSide),
                            restOffsetY(currentPlacement),
                        )
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
                        detectTapGestures { requestRestore(placementNow) }
                    },
            )
        }
    }
}
