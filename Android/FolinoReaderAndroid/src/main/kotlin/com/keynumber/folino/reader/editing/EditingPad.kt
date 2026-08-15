package com.keynumber.folino.reader.editing

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.R

/**
 * The note-input pad: the keys that arm a length and write a pitch, docked above the transport for the duration
 * of an edit session. Android's own placement for the controls iOS keeps in `EditorPadView` (spec §7);
 * `EditingBottomBar` carries the voice selector and the pad toggle that opens this.
 *
 * Two rows, split by job exactly as iOS splits them: row 1 arms or re-times what the NEXT note will be (the
 * durations, the dot), row 2 acts — the pitch letters C-B, then the rest key. Pitch letters are deliberately not
 * localized (a note name is a note name in every language folino ships), which is why [onInputPitch] takes a
 * plain, un-resourced one-letter string — see the call site below for why it is sent lower-case even though the
 * key reads upper-case.
 *
 * The tuplet key and the tie key are second-pass and their slots are left OUT of the row rather than drawn
 * disabled — a visibly dead key reads as broken, not as "coming later". iOS wears both on row 1 beside the
 * durations, but arming a tuplet size and gating the tie key both need controller state
 * (`EditProjection.armedTuplet` / `isCaretInTuplet` / `canAppendTiedNote`) that is not yet projected into
 * `EditUiState`; wiring that is out of this file's scope.
 *
 * A wide window puts every key on ONE row, chosen by MEASURED width ([BoxWithConstraints]'s `maxWidth`), not by a
 * window-size class — an iPad mini and a 13" iPad share the same "expanded" bucket with 400 dp less to spend, so
 * a class-based switch would run the row off the narrower one. [SINGLE_ROW_MIN_WIDTH] is the threshold; below it
 * the two-row layout is the fallback.
 */
@Composable
fun EditingPad(
    armedDurationKind: Int,
    armedDots: Int,
    canWriteRest: Boolean,
    hasEditTarget: Boolean,
    isPlaybackActive: Boolean,
    onArmDuration: (Int) -> Unit,
    onSetArmedDots: (Int) -> Unit,
    onToggleArmedDot: () -> Unit,
    onInputPitch: (String) -> Unit,
    onWriteRest: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // The whole card goes inert TOGETHER while there's nothing to edit, or while the transport is running (the
    // moving playback cursor would otherwise fight the pad for the same caret). Read once and threaded to every
    // key, rather than each key working out its own enabled-ness, so the pad reads as one asleep surface rather
    // than several independently-behaving keys — a custom key like these draws nothing automatically just
    // because a `clickable` is disabled, so this value is what every key's own glyph color keys off of too (see
    // `keyContentColor`), and `canWriteRest` below narrows the rest key ADDITIONALLY, matching iOS's own
    // `viewModel.canWriteRest`-gated delete key.
    val enabled = hasEditTarget && !isPlaybackActive
    val typeface = rememberBravuraTypeface()
    val arming = PadArming(armedDurationKind, armedDots, canWriteRest)
    val actions = PadActions(onArmDuration, onSetArmedDots, onToggleArmedDot, onInputPitch, onWriteRest)

    Surface(
        tonalElevation = 3.dp,
        shape = RoundedCornerShape(20.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        BoxWithConstraints(Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
            if (maxWidth >= SINGLE_ROW_MIN_WIDTH) {
                SingleRow(arming, actions, enabled, typeface)
            } else {
                StackedRows(arming, actions, enabled, typeface)
            }
        }
    }
}

/** The pad's arming state — grouped so the row/key composables below take one parameter instead of three,
 * mirroring `EditSessionController`'s own small grouping data classes (`CalloutAndArming` and friends). */
private data class PadArming(
    val armedDurationKind: Int,
    val armedDots: Int,
    val canWriteRest: Boolean,
)

/** The pad's ops, one field per key group. Every field is a one-line delegation at the call site — see
 * `EditSessionController`'s class doc for why the controller itself never branches; this pad doesn't either. */
private data class PadActions(
    val onArmDuration: (Int) -> Unit,
    val onSetArmedDots: (Int) -> Unit,
    val onToggleArmedDot: () -> Unit,
    val onInputPitch: (String) -> Unit,
    val onWriteRest: () -> Unit,
)

// MARK: Layouts

/** Everything on one row, keys at their fixed minimum width and the two job groups (arm/re-time vs. act) told
 * apart by a divider — the single-row counterpart of [StackedRows]. Fixed widths are what makes this layout
 * measurable, so the caller can compare it against [SINGLE_ROW_MIN_WIDTH] before showing it. */
@Composable
private fun SingleRow(arming: PadArming, actions: PadActions, enabled: Boolean, typeface: Typeface) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(SINGLE_ROW_GAP),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DurationKeys(arming, actions, enabled, typeface, isFlexible = false)
        DotKey(arming, actions, enabled, isFlexible = false)
        PadDivider()
        PitchKeys(actions, enabled, isFlexible = false)
        RestKey(arming, actions, enabled, typeface, isFlexible = false)
    }
}

/** Two rows split by job, not by convenience: row 1 arms or re-times, row 2 writes. Keys share the row's width
 * instead of claiming a fixed minimum, so this layout cannot overflow by construction. */
@Composable
private fun StackedRows(arming: PadArming, actions: PadActions, enabled: Boolean, typeface: Typeface) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            DurationKeys(arming, actions, enabled, typeface, isFlexible = true)
            DotKey(arming, actions, enabled, isFlexible = true)
        }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PitchKeys(actions, enabled, isFlexible = true)
            RestKey(arming, actions, enabled, typeface, isFlexible = true)
        }
    }
}

// MARK: Key groups

/** The duration keys. Tapping arms that length for the next input — it does NOT re-time anything already
 * written. The armed key shows a persistent accent capsule, matching iOS's `PadDurationKey`. */
@Composable
private fun RowScope.DurationKeys(
    arming: PadArming,
    actions: PadActions,
    enabled: Boolean,
    typeface: Typeface,
    isFlexible: Boolean,
) {
    PadDuration.ordered.forEach { entry ->
        PadKey(
            onClick = { actions.onArmDuration(entry.kind) },
            enabled = enabled,
            contentDescription = stringResource(entry.labelRes),
            modifier = keyWidth(isFlexible),
            isArmed = arming.armedDurationKind == entry.kind,
        ) {
            MusicGlyph(entry.noteGlyph, typeface, enabled)
        }
    }
}

/** The seven pitch-letter keys (C...B). Letter names are universal and intentionally not localized — see the
 * class doc. `EditorBridge.inputPitch(letter:)` and the pitch-matching it does downstream expect a lower-case
 * spelling (iOS's own pad lower-cases before calling `viewModel.inputPitch`), so the key sends lower-case even
 * though it reads upper-case. */
@Composable
private fun RowScope.PitchKeys(actions: PadActions, enabled: Boolean, isFlexible: Boolean) {
    PITCH_LETTERS.forEach { letter ->
        PadKey(
            onClick = { actions.onInputPitch(letter.lowercaseChar().toString()) },
            enabled = enabled,
            contentDescription = letter.toString(),
            modifier = keyWidth(isFlexible),
        ) {
            Text(letter.toString(), fontWeight = FontWeight.SemiBold, color = keyContentColor(enabled))
        }
    }
}

/** The dot key: tap adds one augmentation dot (and a second tap clears it), long-press for 1 / 2 / 3 — the
 * Compose equivalent of iOS's `Menu`-with-`primaryAction` `PadDotKey`. Dots and lengths are independent arms
 * (dotted-quarter is the quarter key and this one both lit), so it never sits among the durations as another
 * mutually-exclusive choice. */
@Composable
private fun RowScope.DotKey(arming: PadArming, actions: PadActions, enabled: Boolean, isFlexible: Boolean) {
    var expanded by remember { mutableStateOf(false) }
    Box(keyWidth(isFlexible)) {
        PadKey(
            onClick = actions.onToggleArmedDot,
            onLongClick = { expanded = true },
            enabled = enabled,
            contentDescription = stringResource(R.string.reader_editing_dot),
            isArmed = arming.armedDots > 0,
            modifier = Modifier.fillMaxWidth(),
        ) {
            DotsGlyph(count = arming.armedDots, enabled = enabled)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DOT_CHOICES.forEach { (count, labelRes) ->
                DropdownMenuItem(
                    text = { Text(stringResource(labelRes)) },
                    onClick = {
                        actions.onSetArmedDots(count)
                        expanded = false
                    },
                )
            }
        }
    }
}

/** The rest ("delete") key: turns the SELECTION into a rest of the armed length, so it wears the rest it is
 * about to leave behind rather than a generic backspace glyph — matching iOS's `PadKeyGlyph.rest`. Gated by
 * [PadArming.canWriteRest] ON TOP OF the card's own [enabled], since a rest is never writable at all while
 * nothing is selected, independent of whether editing itself is available. */
@Composable
private fun RowScope.RestKey(
    arming: PadArming,
    actions: PadActions,
    enabled: Boolean,
    typeface: Typeface,
    isFlexible: Boolean,
) {
    val restEnabled = enabled && arming.canWriteRest
    PadKey(
        onClick = actions.onWriteRest,
        enabled = restEnabled,
        contentDescription = stringResource(R.string.reader_editing_delete),
        modifier = keyWidth(isFlexible),
    ) {
        MusicGlyph(PadDuration.restGlyph(arming.armedDurationKind), typeface, restEnabled)
    }
}

private fun RowScope.keyWidth(isFlexible: Boolean): Modifier =
    if (isFlexible) Modifier.weight(1f) else Modifier.width(KEY_MIN_WIDTH)

private val DOT_CHOICES = listOf(
    1 to R.string.reader_editing_dot_single,
    2 to R.string.reader_editing_dot_double,
    3 to R.string.reader_editing_dot_triple,
)

/** `internal` (not `private`) so `PadSingleRowWidthTest` can pin [SINGLE_ROW_KEY_COUNT] against this list's real
 * size rather than a copy of "7". */
internal val PITCH_LETTERS = listOf('C', 'D', 'E', 'F', 'G', 'A', 'B')

// MARK: One key

/** One pad key's surface: fixed size, rounded, an accent capsule while [isArmed], and press feedback via the
 * platform's default ripple. [enabled] gates the click (through `combinedClickable`, which — unlike a stock
 * Material `Button` — applies NO dimming of its own) and is otherwise left to [content] to read for its own
 * color, exactly as iOS's `PadKeyChrome` pins every key's foreground to `.primary` / `.tertiary` off the same
 * `isEnabled` value rather than layering a second, container-level fade on top. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PadKey(
    onClick: () -> Unit,
    enabled: Boolean,
    contentDescription: String,
    modifier: Modifier = Modifier,
    isArmed: Boolean = false,
    onLongClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(percent = 50)
    val armedColor = MaterialTheme.colorScheme.primary.copy(alpha = if (enabled) 0.22f else 0.10f)
    Box(
        modifier
            .height(KEY_HEIGHT)
            .clip(shape)
            .background(if (isArmed) armedColor else Color.Transparent, shape)
            .combinedClickable(enabled = enabled, onClick = onClick, onLongClick = onLongClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

/** A key's glyph/letter color: `.primary`-equivalent while [enabled], dimmed otherwise — the one place every key
 * reads the shared enabled-ness from, so the pad dims as a whole rather than key by key. */
@Composable
private fun keyContentColor(enabled: Boolean): Color =
    if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)

/** A duration/rest key's glyph, drawn through a native `Canvas`/`Paint` rather than Compose `Text` — see
 * `rememberBravuraTypeface`'s doc for why — and centered on the box by deriving the baseline from
 * [Paint.getFontMetrics], the same technique `DisplayInspectorSheet`'s `ClefTile` uses for the same font. */
@Composable
private fun MusicGlyph(char: Char, typeface: Typeface, enabled: Boolean, modifier: Modifier = Modifier) {
    val colorArgb = keyContentColor(enabled).toArgb()
    Canvas(modifier.size(GLYPH_SIZE)) {
        val paint = Paint().apply {
            isAntiAlias = true
            this.typeface = typeface
            textSize = GLYPH_SIZE.toPx()
            color = colorArgb
            textAlign = Paint.Align.CENTER
        }
        val metrics = paint.fontMetrics
        val baseline = size.height / 2f - (metrics.ascent + metrics.descent) / 2f
        drawIntoCanvas {
            it.nativeCanvas.drawText(char.toString(), size.width / 2f, baseline, paint)
        }
    }
}

/** [count] filled dots in a row, and a single (unfilled-looking, since [keyContentColor] already carries the
 * enabled dimming) one when [count] is 0 — the key has to show what it offers even when it's off. Drawn as
 * shapes rather than `MusicGlyphs.AUGMENTATION_DOT`; see that constant's doc for why. */
@Composable
private fun DotsGlyph(count: Int, enabled: Boolean, modifier: Modifier = Modifier) {
    val color = keyContentColor(enabled)
    val shown = count.coerceAtLeast(1)
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(DOT_GAP)) {
        repeat(shown) {
            Box(Modifier.size(DOT_DIAMETER).background(color, CircleShape))
        }
    }
}

/** The divider separating the pad's two job groups (arm/re-time vs. act) on the single-row layout. */
@Composable
private fun PadDivider() {
    Box(
        Modifier
            .padding(horizontal = DIVIDER_HORIZONTAL_PADDING)
            .width(DIVIDER_LINE_WIDTH)
            .height(DIVIDER_HEIGHT)
            .background(MaterialTheme.colorScheme.outlineVariant),
    )
}

// MARK: Sizing

private val KEY_HEIGHT: Dp = 48.dp
private val GLYPH_SIZE: Dp = 22.dp
private val DIVIDER_HEIGHT: Dp = 28.dp
private val DIVIDER_LINE_WIDTH: Dp = 1.dp
private val DIVIDER_HORIZONTAL_PADDING: Dp = 2.dp
private val DOT_DIAMETER: Dp = 4.dp
private val DOT_GAP: Dp = 3.dp

/** A key's fixed width on the single-row layout. `internal` (not `private`) so `PadSingleRowWidthTest` can pin
 * [SINGLE_ROW_MIN_WIDTH] against the exact value [SingleRow] uses, not a second copy of the number. */
internal val KEY_MIN_WIDTH: Dp = 44.dp

/** The gap `SingleRow`'s own `Arrangement.spacedBy` uses — `internal` for the same reason as [KEY_MIN_WIDTH]. */
internal val SINGLE_ROW_GAP: Dp = 6.dp

/** [PadDivider]'s total footprint on the row: the line's own width plus the padding wrapped around both sides
 * of it (see [PadDivider]) — what a fixed-width sibling actually costs the row, not just the line's width. */
internal val DIVIDER_FOOTPRINT_WIDTH: Dp = DIVIDER_LINE_WIDTH + DIVIDER_HORIZONTAL_PADDING * 2

/**
 * How many individual keys [SingleRow] lays out today: [PadDuration.ordered]'s duration keys, the dot key, the
 * seven [PITCH_LETTERS] pitch keys, and the rest key — the same counts [DurationKeys]/[DotKey]/[PitchKeys]/
 * [RestKey] actually emit, not a copy of the number. **When the tuplet/tie keys land** (see the class doc — they
 * are second-pass and not drawn yet), whoever adds them to [SingleRow] must add their count here too, or this
 * value silently undercounts again exactly as [SINGLE_ROW_MIN_WIDTH] once did.
 */
internal val SINGLE_ROW_KEY_COUNT: Int
    get() = PadDuration.ordered.size + 1 + PITCH_LETTERS.size + 1

/**
 * Below this measured width the single row does not fit — see the class doc for why that has to be measured
 * rather than read off the window-size class.
 *
 * **Derived, not hand-picked.** [SingleRow] lays out [SINGLE_ROW_KEY_COUNT] keys at [KEY_MIN_WIDTH] plus one
 * divider at [DIVIDER_FOOTPRINT_WIDTH], all separated by [SINGLE_ROW_GAP] — `Arrangement.spacedBy` puts a gap
 * between every pair of ADJACENT children, so `(children - 1)` gaps for `(SINGLE_ROW_KEY_COUNT + 1)` children
 * (the `+ 1` is the divider). [singleRowRequiredWidthDp] is that arithmetic, pulled out into a plain function so
 * `PadSingleRowWidthTest` can pin it without a Compose/Robolectric dependency.
 *
 * A hand-computed constant here previously undercounted the row (640.dp against an actual ~705.dp requirement,
 * caught in review) — any measured card width in that gap picked the single-row layout and it ran off the card,
 * unscrollable and unclipped. Deriving this from the same values [SingleRow] uses is what makes that class of
 * bug impossible rather than merely fixed once.
 */
internal val SINGLE_ROW_MIN_WIDTH: Dp
    get() = singleRowRequiredWidthDp(
        keyCount = SINGLE_ROW_KEY_COUNT,
        keyWidthDp = KEY_MIN_WIDTH.value,
        gapDp = SINGLE_ROW_GAP.value,
        dividerFootprintDp = DIVIDER_FOOTPRINT_WIDTH.value,
    ).dp

/**
 * The width (in dp magnitude, not [Dp]) that [SingleRow] needs to lay out [keyCount] fixed-width keys plus one
 * divider, all separated by [gapDp] gaps. Plain `Float` arithmetic rather than [Dp] so it has no
 * Compose-runtime dependency and `PadSingleRowWidthTest` can call it directly from a plain JVM test (this
 * module's unit tests have no Robolectric — see the module's other tests for why).
 */
internal fun singleRowRequiredWidthDp(
    keyCount: Int,
    keyWidthDp: Float,
    gapDp: Float,
    dividerFootprintDp: Float,
): Float {
    val childCount = keyCount + 1 // the divider is one more child than the keys alone
    val gapCount = childCount - 1
    return keyCount * keyWidthDp + dividerFootprintDp + gapCount * gapDp
}

// MARK: Previews

@Preview(name = "Editing pad - stacked (360 dp)", showBackground = true)
@Composable
private fun EditingPadStackedPreview() {
    Box(Modifier.width(360.dp).padding(8.dp)) {
        EditingPad(
            armedDurationKind = 3,
            armedDots = 1,
            canWriteRest = true,
            hasEditTarget = true,
            isPlaybackActive = false,
            onArmDuration = {},
            onSetArmedDots = {},
            onToggleArmedDot = {},
            onInputPitch = {},
            onWriteRest = {},
        )
    }
}

/**
 * 680 dp: inside the old, hand-picked `SINGLE_ROW_MIN_WIDTH` (640.dp) but under the row's real ~705.dp
 * requirement — exactly the gap that ran the single row off the card (see [SINGLE_ROW_MIN_WIDTH]'s doc). Now
 * that the threshold is derived rather than hand-picked, this width falls below it and renders stacked; if it
 * ever renders single-row and overflows again, this is the preview that would show it.
 */
@Preview(name = "Editing pad - guard band (680 dp)", showBackground = true)
@Composable
private fun EditingPadGuardBandPreview() {
    Box(Modifier.width(680.dp).padding(8.dp)) {
        EditingPad(
            armedDurationKind = 3,
            armedDots = 0,
            canWriteRest = true,
            hasEditTarget = true,
            isPlaybackActive = false,
            onArmDuration = {},
            onSetArmedDots = {},
            onToggleArmedDot = {},
            onInputPitch = {},
            onWriteRest = {},
        )
    }
}

@Preview(name = "Editing pad - single row (840 dp)", showBackground = true)
@Composable
private fun EditingPadSingleRowPreview() {
    Box(Modifier.width(840.dp).padding(8.dp)) {
        EditingPad(
            armedDurationKind = 4,
            armedDots = 0,
            canWriteRest = false,
            hasEditTarget = true,
            isPlaybackActive = false,
            onArmDuration = {},
            onSetArmedDots = {},
            onToggleArmedDot = {},
            onInputPitch = {},
            onWriteRest = {},
        )
    }
}

@Preview(name = "Editing pad - inert (no edit target)", showBackground = true)
@Composable
private fun EditingPadInertPreview() {
    Box(Modifier.width(360.dp).padding(8.dp)) {
        EditingPad(
            armedDurationKind = 0,
            armedDots = 0,
            canWriteRest = false,
            hasEditTarget = false,
            isPlaybackActive = false,
            onArmDuration = {},
            onSetArmedDots = {},
            onToggleArmedDot = {},
            onInputPitch = {},
            onWriteRest = {},
        )
    }
}
