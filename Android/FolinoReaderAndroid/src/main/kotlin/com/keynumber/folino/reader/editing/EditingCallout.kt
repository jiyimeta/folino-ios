package com.keynumber.folino.reader.editing

import android.graphics.Typeface
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.R
import io.github.jiyimeta.sheetmusic.audio.model.EditCaretFrame
import kotlin.math.roundToInt

/**
 * The floor a zero-width SELECTION rect is widened to, in document millimetres — matching iOS's
 * `document.editingCaretRect(for:in:minimumWidth: 1)` (`EditingSelectionOverlay.swift`). Narrower than the
 * caret's own [EDIT_CARET_MINIMUM_WIDTH_MM]: the callout only needs a horizontal point to park beside, not a
 * column wide enough to read as an insertion mark.
 */
internal const val EDIT_CALLOUT_MINIMUM_WIDTH_MM = 1.0

/** Gap between the selection and the card, and how close to the viewport's own edges the card may go — the
 * Android counterpart of iOS `SelectionCalloutLayer`'s `noteGap` / `edgeInset`, without that layer's persisted
 * placement preference or drag gesture (see the class doc: placement here is Android's own, though the
 * prefer-above/fall-back-below RULE itself is not). */
private val CALLOUT_GAP = 12.dp
private val CALLOUT_EDGE_INSET = 8.dp

private val SUMMARY_KEY_WIDTH = 60.dp
private val CHEVRON_SIZE = 14.dp

// MARK: Placement

/** Which side of the selection the callout card parks on — the two options [resolveCalloutPlacement] chooses
 * between. Android's own reduction of iOS `SelectionCalloutLayer`'s identically-named `CalloutSide`: that file
 * additionally persists a preference and lets the reader drag between the two, neither of which this file does
 * (see [EditingCallout]'s class doc). */
internal enum class CalloutSide { ABOVE, BELOW }

/** The resolved placement [resolveCalloutPlacement] returns: which [side] the card parks on, and its final
 * top-left [offset] in the same local px space the selection rect is given in. */
internal data class CalloutPlacement(val offset: IntOffset, val side: CalloutSide)

/**
 * Resolves where the callout card sits beside a selection — a pure function of already-resolved primitives (the
 * mm→px conversion, the live pinch scale/pan, the viewport's own px size), extracted for exactly the reason
 * `EditingPad.kt`'s `singleRowRequiredWidthDp` was: a plain JVM test ([CalloutPlacementTest]) can pin this
 * arithmetic directly, no Compose runtime required, and this class of bug (an off-by-a-clamp overlap) is
 * precisely the kind static reading misses and a test catches.
 *
 * **Prefers [CalloutSide.ABOVE]; falls back to [CalloutSide.BELOW] only when there is not enough room above
 * within the current viewport** — i.e. the unclamped above position would run past the viewport's own top edge.
 * Mirrors iOS's `SelectionCalloutLayer.availableSides` / `resolved(side:)` rule (prefer above, fall back below,
 * never overlap the selection when either side has room), minus that file's persisted preference and drag
 * gesture. The decision itself is never rescued by a clamp — the SIDE is chosen first, purely from which one
 * avoids overlap, exactly as iOS's `availableSides` decides before `position(for:in:side:)` ever clamps
 * anything.
 *
 * **Once a side is chosen, Y clamps into the FULL viewport as a last resort** — matching iOS's
 * `position(for:in:side:)`, which clamps `rawY` into `[topLimit, bottomLimit]` unconditionally, regardless of
 * which side was picked. In the ordinary case this clamp is inert: the side was chosen precisely because its
 * unclamped position already sits inside the viewport, so the clamp changes nothing. It only engages in the
 * degenerate case — a viewport too short to fit the card on EITHER side — where iOS's own comment on
 * `availableSides` states the trade explicitly ("keep both and let the clamp ... decide"): a card the reader
 * cannot see at all is worse than one that overlaps the note, so staying on screen wins. X clamps across the
 * full viewport width regardless of side, since sliding sideways never risks covering the selection.
 */
internal fun resolveCalloutPlacement(
    selLeftPx: Float,
    selTopPx: Float,
    selWidthPx: Float,
    selHeightPx: Float,
    cardWidthPx: Float,
    cardHeightPx: Float,
    gapPx: Float,
    edgeInsetPx: Float,
    viewportPanPx: Offset,
    viewportSizePx: IntSize,
    bottomClearancePx: Float = 0f,
): CalloutPlacement {
    val minX = viewportPanPx.x + edgeInsetPx
    val maxX = (viewportPanPx.x + viewportSizePx.width - cardWidthPx - edgeInsetPx).coerceAtLeast(minX)
    val rawX = selLeftPx + selWidthPx / 2f - cardWidthPx / 2f
    val x = rawX.coerceIn(minX, maxX)

    val viewportTopPx = viewportPanPx.y + edgeInsetPx
    // The floating editing chrome covers the bottom of the viewport — the transport's band, plus the pad while it
    // is out — so the usable bottom is that much higher than the viewport's own. iOS passes the same figure into
    // `SelectionCalloutLayer(bottomClearance:)`, and for the same reason: the callout carries the pitch steps, and
    // a card parked under the pad is a control the reader cannot reach.
    val viewportBottomPx = viewportPanPx.y + viewportSizePx.height - bottomClearancePx - edgeInsetPx
    val aboveY = selTopPx - gapPx - cardHeightPx
    val belowY = selTopPx + selHeightPx + gapPx

    // The side decision itself sees the UNCLAMPED positions only — no clamp rescues a bad choice here.
    val side = if (aboveY >= viewportTopPx) CalloutSide.ABOVE else CalloutSide.BELOW
    val rawY = if (side == CalloutSide.ABOVE) aboveY else belowY

    // Last-resort containment, applied AFTER the side is picked and regardless of which side it was — see the
    // doc above for why this has to be unconditional rather than scoped to one side.
    val minY = viewportTopPx
    val maxY = (viewportBottomPx - cardHeightPx).coerceAtLeast(minY)
    val y = rawY.coerceIn(minY, maxY)

    return CalloutPlacement(IntOffset(x.roundToInt(), y.roundToInt()), side)
}

/**
 * The contextual callout: a small card that floats beside the selected note or rest, carrying its length (behind
 * a tap, [durationKind]/[dots]) and — for a note — the pitch steps that alter it. Content spec:
 * `EditorCalloutView.swift`'s doc comment (`Packages/Features/Editor`) — the pitch keys are chevrons rather than
 * accidentals because what they do is STEP, one semitone per tap in whatever spelling the key signature calls
 * for, and a ♯ that sometimes produces a ♮ reads as a broken accidental button. A REST gets the same card minus
 * the pitch steps ([isNoteSelected] is the switch) — there is no pitch to step and, since the tie key is
 * second-pass anyway (see below), nothing else a rest has no answer for.
 *
 * Placement is not a port of iOS's draggable above/below layer (`SelectionCalloutLayer.swift`) — no persisted
 * preference, no drag gesture — but it DOES follow that layer's own above/below RULE: prefer above the
 * selection, fall back to below when there is not enough room above within the current viewport, and clamp
 * horizontally into the viewport either way. See [resolveCalloutPlacement], the pure function this composable
 * delegates the decision to. [rectMm] is the SELECTION's own caret-shaped rect —
 * `caretRectMm(handle, selectedItemBytes, EDIT_CALLOUT_MINIMUM_WIDTH_MM)`, never the caret's own — converted to
 * px with the same `mm * pxPerMM * scale` arithmetic [EditingCaretOverlay] draws with, so this composable must be
 * mounted in the SAME node: a sibling of the score, inside the panning `graphicsLayer`'s content box, so pan and
 * zoom carry the card with the score exactly as they carry the caret. [vPadPx] folds in the same top padding that
 * node's sibling overlays apply via a `Modifier.padding` — this one bakes it into the offset math instead, since
 * a custom `Modifier.offset` (needed for the clamp below) and a padding modifier upstream of it don't compose the
 * way two padding modifiers would.
 *
 * [viewportPanPx] and [viewportSizePx] are what the clamp measures against: the current scroll offset (this
 * node's own local coordinate space is panned but not clamped — a document-tall/-wide box, per
 * `ReadyScore`'s content Box) and the on-screen viewport's pixel size, both already tracked by `ReadyScore` for
 * its own gesture math.
 *
 * `null` [rectMm] draws nothing: no selection, or an ID a reflow already overtook. The caller additionally gates
 * this on `EditUiState.hasSelectionCallout` — there is no empty state to show while gated off.
 */
@Composable
fun EditingCallout(
    rectMm: EditCaretFrame?,
    isNoteSelected: Boolean,
    durationKind: Int,
    dots: Int,
    isPlaybackActive: Boolean,
    pxPerMM: Float,
    scale: Float,
    vPadPx: Float,
    viewportPanPx: Offset,
    viewportSizePx: IntSize,
    /** Room the floating editing chrome occupies at the bottom of the viewport — see [resolveCalloutPlacement]. */
    bottomClearancePx: Float = 0f,
    onSetDuration: (Int) -> Unit,
    onSetDots: (Int) -> Unit,
    onToggleDot: () -> Unit,
    onShiftPitch: (Int) -> Unit,
    onShiftOctave: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (rectMm == null) return

    val density = LocalDensity.current
    val gapPx = with(density) { CALLOUT_GAP.toPx() }
    val edgeInsetPx = with(density) { CALLOUT_EDGE_INSET.toPx() }
    // Measured, not assumed: the card's size decides how far above the selection it has to sit and how close to
    // the viewport edges it may go. Read inside the `offset` block below, one frame behind — the same lag
    // `SelectionCalloutLayer.swift`'s own `@State private var calloutSize` accepts for the same reason.
    var cardSize by remember { mutableStateOf(IntSize.Zero) }

    Box(
        modifier.offset {
            val selLeftPx = rectMm.xMm.toFloat() * pxPerMM * scale
            val selTopPx = vPadPx + rectMm.yMm.toFloat() * pxPerMM * scale
            val selWidthPx = rectMm.widthMm.toFloat() * pxPerMM * scale
            val selHeightPx = rectMm.heightMm.toFloat() * pxPerMM * scale

            resolveCalloutPlacement(
                selLeftPx = selLeftPx,
                selTopPx = selTopPx,
                selWidthPx = selWidthPx,
                selHeightPx = selHeightPx,
                cardWidthPx = cardSize.width.toFloat(),
                cardHeightPx = cardSize.height.toFloat(),
                gapPx = gapPx,
                edgeInsetPx = edgeInsetPx,
                viewportPanPx = viewportPanPx,
                viewportSizePx = viewportSizePx,
                bottomClearancePx = bottomClearancePx,
            ).offset
        },
    ) {
        EditingCalloutCard(
            isNoteSelected = isNoteSelected,
            durationKind = durationKind,
            dots = dots,
            enabled = !isPlaybackActive,
            onSetDuration = onSetDuration,
            onSetDots = onSetDots,
            onToggleDot = onToggleDot,
            onShiftPitch = onShiftPitch,
            onShiftOctave = onShiftOctave,
            modifier = Modifier.onSizeChanged { cardSize = it },
        )
    }
}

/** The card itself: a pill while its length tray is closed, a rounded rectangle once it opens — a capsule around
 * two rows would bulge into semicircular ends wide enough to crowd the corner keys, matching iOS's identical
 * `cardShape` rule. */
@Composable
private fun EditingCalloutCard(
    isNoteSelected: Boolean,
    durationKind: Int,
    dots: Int,
    enabled: Boolean,
    onSetDuration: (Int) -> Unit,
    onSetDots: (Int) -> Unit,
    onToggleDot: () -> Unit,
    onShiftPitch: (Int) -> Unit,
    onShiftOctave: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    var isTrayOpen by remember { mutableStateOf(false) }
    val typeface = rememberBravuraTypeface()

    Surface(
        tonalElevation = 3.dp,
        shape = if (isTrayOpen) RoundedCornerShape(20.dp) else RoundedCornerShape(percent = 50),
        modifier = modifier,
    ) {
        Column(
            Modifier.padding(horizontal = 8.dp, vertical = if (isTrayOpen) 4.dp else 0.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                DurationSummaryKey(
                    isNoteSelected = isNoteSelected,
                    durationKind = durationKind,
                    dots = dots,
                    enabled = enabled,
                    typeface = typeface,
                    isTrayOpen = isTrayOpen,
                    onToggleTray = { isTrayOpen = !isTrayOpen },
                )
                // Nothing after the summary on a rest — a divider with one side empty reads as a missing key
                // rather than as a separator (iOS `EditorCalloutView.body`'s identical call).
                if (isNoteSelected) {
                    PadDivider()
                    PadKey(
                        onClick = { onShiftPitch(1) },
                        onLongClick = { onShiftOctave(1) },
                        enabled = enabled,
                        contentDescription = stringResource(R.string.reader_editing_pitch_up),
                        modifier = Modifier.width(KEY_MIN_WIDTH),
                    ) {
                        Icon(
                            Icons.Filled.KeyboardArrowUp,
                            contentDescription = null,
                            tint = keyContentColor(enabled),
                        )
                    }
                    PadKey(
                        onClick = { onShiftPitch(-1) },
                        onLongClick = { onShiftOctave(-1) },
                        enabled = enabled,
                        contentDescription = stringResource(R.string.reader_editing_pitch_down),
                        modifier = Modifier.width(KEY_MIN_WIDTH),
                    ) {
                        Icon(
                            Icons.Filled.KeyboardArrowDown,
                            contentDescription = null,
                            tint = keyContentColor(enabled),
                        )
                    }
                    // The tie key's slot: second-pass. `EditUiState.canTie` / `isSelectionTied` are wired
                    // (`EditSessionController`) but not drawn here, matching the pad's own rule that a visibly
                    // dead key reads as broken rather than as "coming later" (`EditingPad.kt`'s class doc).
                }
            }

            if (isTrayOpen) {
                DurationTray(
                    isNoteSelected = isNoteSelected,
                    durationKind = durationKind,
                    dots = dots,
                    enabled = enabled,
                    typeface = typeface,
                    onSetDuration = onSetDuration,
                    onSetDots = onSetDots,
                    onToggleDot = onToggleDot,
                )
            }
        }
    }
}

/** The SELECTED item's length — not the armed one. The pad answers "what comes next"; the callout answers "what
 * is THIS", and changing it here re-times the selection ([onSetDuration] / [onSetDots] →
 * `EditSessionController.setSelectionDuration` / `.setSelectionDots`), not what gets written next. */
@Composable
private fun DurationSummaryKey(
    isNoteSelected: Boolean,
    durationKind: Int,
    dots: Int,
    enabled: Boolean,
    typeface: Typeface,
    isTrayOpen: Boolean,
    onToggleTray: () -> Unit,
) {
    val glyph = if (isNoteSelected) PadDuration.noteGlyph(durationKind) else PadDuration.restGlyph(durationKind)
    val description = stringResource(
        if (isNoteSelected) {
            R.string.reader_editing_callout_note_length
        } else {
            R.string.reader_editing_callout_rest_length
        },
    )
    PadKey(
        onClick = onToggleTray,
        enabled = enabled,
        contentDescription = description,
        isArmed = isTrayOpen,
        modifier = Modifier.width(SUMMARY_KEY_WIDTH),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            MusicGlyph(glyph, typeface, enabled)
            if (dots > 0) DotsGlyph(count = dots, enabled = enabled)
            Icon(
                imageVector = if (isTrayOpen) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                contentDescription = null,
                tint = keyContentColor(enabled),
                modifier = Modifier.size(CHEVRON_SIZE),
            )
        }
    }
}

/** The length choices behind the summary key: the same five keys the pad's row 1 offers, wearing rest glyphs
 * instead of note glyphs on a rest — see [PadDuration.restGlyph] — so the tray's shape never changes, only what
 * its keys are pictures OF (iOS `EditorCalloutView.durationTray`'s identical rule). */
@Composable
private fun DurationTray(
    isNoteSelected: Boolean,
    durationKind: Int,
    dots: Int,
    enabled: Boolean,
    typeface: Typeface,
    onSetDuration: (Int) -> Unit,
    onSetDots: (Int) -> Unit,
    onToggleDot: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
        PadDuration.ordered.forEach { entry ->
            PadKey(
                onClick = { onSetDuration(entry.kind) },
                enabled = enabled,
                contentDescription = stringResource(entry.labelRes),
                isArmed = durationKind == entry.kind,
                modifier = Modifier.width(KEY_MIN_WIDTH),
            ) {
                MusicGlyph(if (isNoteSelected) entry.noteGlyph else entry.restGlyph, typeface, enabled)
            }
        }
        CalloutDotKey(dots = dots, enabled = enabled, onSetDots = onSetDots, onToggleDot = onToggleDot)
    }
}

/** The dot key, scoped to the SELECTION rather than an arming — the callout's counterpart to `EditingPad`'s own
 * `DotKey`, which it cannot reuse directly (that one is wired to the pad's arm-the-next-note vocabulary). Same
 * tap-toggles / long-press-for-1-2-3 behavior, via the shared [DOT_CHOICES]. */
@Composable
private fun CalloutDotKey(dots: Int, enabled: Boolean, onSetDots: (Int) -> Unit, onToggleDot: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box(Modifier.width(KEY_MIN_WIDTH)) {
        PadKey(
            onClick = onToggleDot,
            onLongClick = { expanded = true },
            enabled = enabled,
            contentDescription = stringResource(R.string.reader_editing_dot),
            isArmed = dots > 0,
            modifier = Modifier.fillMaxWidth(),
        ) {
            DotsGlyph(count = dots, enabled = enabled)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DOT_CHOICES.forEach { (count, labelRes) ->
                DropdownMenuItem(
                    text = { Text(stringResource(labelRes)) },
                    onClick = {
                        onSetDots(count)
                        expanded = false
                    },
                )
            }
        }
    }
}

// MARK: Previews

@Preview(name = "Callout — note, collapsed", showBackground = true)
@Composable
private fun EditingCalloutNotePreview() {
    Box(Modifier.size(320.dp, 480.dp)) {
        EditingCallout(
            rectMm = EditCaretFrame(xMm = 40.0, yMm = 60.0, widthMm = 4.0, heightMm = 8.0),
            isNoteSelected = true,
            durationKind = 3,
            dots = 0,
            isPlaybackActive = false,
            pxPerMM = 4f,
            scale = 1f,
            vPadPx = 0f,
            viewportPanPx = Offset.Zero,
            viewportSizePx = IntSize(320, 480),
            onSetDuration = {},
            onSetDots = {},
            onToggleDot = {},
            onShiftPitch = {},
            onShiftOctave = {},
        )
    }
}

@Preview(name = "Callout — dotted rest, collapsed", showBackground = true)
@Composable
private fun EditingCalloutRestPreview() {
    Box(Modifier.size(320.dp, 480.dp)) {
        EditingCallout(
            rectMm = EditCaretFrame(xMm = 40.0, yMm = 60.0, widthMm = 4.0, heightMm = 8.0),
            isNoteSelected = false,
            durationKind = 3,
            dots = 1,
            isPlaybackActive = false,
            pxPerMM = 4f,
            scale = 1f,
            vPadPx = 0f,
            viewportPanPx = Offset.Zero,
            viewportSizePx = IntSize(320, 480),
            onSetDuration = {},
            onSetDots = {},
            onToggleDot = {},
            onShiftPitch = {},
            onShiftOctave = {},
        )
    }
}

/** Selection parked one gap above the viewport's top-left corner: without the clamp in [EditingCallout], the
 * card's default above-the-selection placement would run half off the top of the screen. */
@Preview(name = "Callout — clamped near the top-left edge", showBackground = true)
@Composable
private fun EditingCalloutEdgeClampPreview() {
    Box(Modifier.size(320.dp, 480.dp)) {
        EditingCallout(
            rectMm = EditCaretFrame(xMm = 2.0, yMm = 1.0, widthMm = 4.0, heightMm = 8.0),
            isNoteSelected = true,
            durationKind = 5,
            dots = 0,
            isPlaybackActive = false,
            pxPerMM = 4f,
            scale = 1f,
            vPadPx = 0f,
            viewportPanPx = Offset.Zero,
            viewportSizePx = IntSize(320, 480),
            onSetDuration = {},
            onSetDots = {},
            onToggleDot = {},
            onShiftPitch = {},
            onShiftOctave = {},
        )
    }
}

@Preview(name = "Callout — inert while playback runs", showBackground = true)
@Composable
private fun EditingCalloutDisabledPreview() {
    Box(Modifier.size(320.dp, 480.dp)) {
        EditingCallout(
            rectMm = EditCaretFrame(xMm = 40.0, yMm = 60.0, widthMm = 4.0, heightMm = 8.0),
            isNoteSelected = true,
            durationKind = 3,
            dots = 0,
            isPlaybackActive = true,
            pxPerMM = 4f,
            scale = 1f,
            vPadPx = 0f,
            viewportPanPx = Offset.Zero,
            viewportSizePx = IntSize(320, 480),
            onSetDuration = {},
            onSetDots = {},
            onToggleDot = {},
            onShiftPitch = {},
            onShiftOctave = {},
        )
    }
}

/** The length tray alone, at a fixed-open state a live [EditingCallout] preview cannot reach (its disclosure is
 * `remember`ed state with no seam to force open) — this is what tapping the summary key reveals. */
@Preview(name = "Callout — duration tray", showBackground = true)
@Composable
private fun EditingCalloutDurationTrayPreview() {
    Surface(tonalElevation = 3.dp, shape = RoundedCornerShape(20.dp)) {
        Box(Modifier.padding(8.dp)) {
            DurationTray(
                isNoteSelected = true,
                durationKind = 3,
                dots = 1,
                enabled = true,
                typeface = rememberBravuraTypeface(),
                onSetDuration = {},
                onSetDots = {},
                onToggleDot = {},
            )
        }
    }
}
