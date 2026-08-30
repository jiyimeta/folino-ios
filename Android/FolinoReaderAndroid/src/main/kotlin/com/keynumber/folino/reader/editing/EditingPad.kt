package com.keynumber.folino.reader.editing

import android.graphics.Paint
import android.graphics.Rect
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
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
import com.keynumber.folino.editor.DEFAULT_TUPLET_SIZE
import com.keynumber.folino.reader.R

/**
 * The note-input pad: the keys that arm a length and write a pitch, floating over the score for the duration of
 * an edit session. Android's own placement for the controls iOS keeps in `EditorPadView` (spec §7).
 *
 * Two rows, split by job exactly as iOS splits them (`EditorPadView.stackedRows`):
 *  1. what the NEXT note will be — the durations, the tuplet key, the tie key, the dot key, the add-to-chord arm;
 *  2. what to write — the pitch letters C-B and the rest key.
 *
 * Pitch letters are deliberately not localized (a note name is a note name in every language folino ships),
 * which is why [PadActions.onInputPitch] takes a plain, un-resourced one-letter string — see [PitchKeys] for why
 * it is sent lower-case even though the key reads upper-case.
 *
 * **The ← / → steppers are NOT here.** They were, briefly, and before that they had a fixed row of their own with
 * the voice selector; both of those are gone. Stepping the caret is navigation, not writing, so it sits beside the
 * transport in a pill of its own ([EditingStepperPill]) — where iOS puts it, and where it survives the pad being
 * tucked away, which is exactly when you still want it.
 *
 * **The pad is dismissed by dragging it past a side edge**, not by a toggle in the app bar — see [EditingPadTuck],
 * which owns that motion and hands this composable to it as content.
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
    canTie: Boolean,
    isSelectionTied: Boolean,
    canAppendTiedNote: Boolean,
    isCaretInTuplet: Boolean,
    armedTuplet: Int,
    isAddToChordArmed: Boolean,
    hasEditTarget: Boolean,
    isPlaybackActive: Boolean,
    onArmDuration: (Int) -> Unit,
    onSetArmedDots: (Int) -> Unit,
    onToggleArmedDot: () -> Unit,
    onInputPitch: (String) -> Unit,
    onWriteRest: () -> Unit,
    onToggleTie: () -> Unit,
    onAppendTiedNote: () -> Unit,
    onCreateTuplet: (Int) -> Unit,
    onRemoveTuplet: () -> Unit,
    onToggleAddToChord: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // The whole card goes inert TOGETHER while there's nothing to edit, or while the transport is running (the
    // moving playback cursor would otherwise fight the pad for the same caret). Read once and threaded to every
    // key, rather than each key working out its own enabled-ness, so the pad reads as one asleep surface rather
    // than several independently-behaving keys — a custom key like these draws nothing automatically just
    // because a `clickable` is disabled, so this value is what every key's own glyph color keys off of too (see
    // `keyContentColor`), and the per-key flags below (`canWriteRest`, `canTie`/`canAppendTiedNote`) narrow
    // individual keys ADDITIONALLY, matching iOS's own per-key `.disabled(...)` on the same conditions.
    val enabled = hasEditTarget && !isPlaybackActive
    val typeface = rememberBravuraTypeface()
    val arming = PadArming(
        armedDurationKind = armedDurationKind,
        armedDots = armedDots,
        canWriteRest = canWriteRest,
        canTie = canTie,
        isSelectionTied = isSelectionTied,
        canAppendTiedNote = canAppendTiedNote,
        isCaretInTuplet = isCaretInTuplet,
        armedTuplet = armedTuplet,
        isAddToChordArmed = isAddToChordArmed,
    )
    val actions = PadActions(
        onArmDuration = onArmDuration,
        onSetArmedDots = onSetArmedDots,
        onToggleArmedDot = onToggleArmedDot,
        onInputPitch = onInputPitch,
        onWriteRest = onWriteRest,
        onToggleTie = onToggleTie,
        onAppendTiedNote = onAppendTiedNote,
        onCreateTuplet = onCreateTuplet,
        onRemoveTuplet = onRemoveTuplet,
        onToggleAddToChord = onToggleAddToChord,
    )

    Surface(
        tonalElevation = 3.dp,
        // The pad floats over the score now, so it needs the same lift [EditingStepperPill] has: a light card on
        // white paper otherwise has no edge at all and reads as part of the page. This is where the two platforms
        // do the same thing by different means — iOS's card is a glass material (`regularGlassCompat`), which
        // carries its own separation and needs no drop shadow; Material's answer to "this surface floats" is
        // elevation.
        shadowElevation = 3.dp,
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

/** The pad's arming state — grouped so the row/key composables below take one parameter instead of nine,
 * mirroring `EditSessionController`'s own small grouping data classes (`CalloutAndArming` and friends). */
private data class PadArming(
    val armedDurationKind: Int,
    val armedDots: Int,
    val canWriteRest: Boolean,
    val canTie: Boolean,
    val isSelectionTied: Boolean,
    val canAppendTiedNote: Boolean,
    val isCaretInTuplet: Boolean,
    val armedTuplet: Int,
    val isAddToChordArmed: Boolean,
)

/** The pad's ops, one field per key group. Every field is a one-line delegation at the call site — see
 * `EditSessionController`'s class doc for why the controller itself never branches; this pad doesn't either,
 * with the one documented exception of [TieKey], whose branch exists because Android has no second tie key to
 * split the two meanings across (see that composable). */
private data class PadActions(
    val onArmDuration: (Int) -> Unit,
    val onSetArmedDots: (Int) -> Unit,
    val onToggleArmedDot: () -> Unit,
    val onInputPitch: (String) -> Unit,
    val onWriteRest: () -> Unit,
    val onToggleTie: () -> Unit,
    val onAppendTiedNote: () -> Unit,
    val onCreateTuplet: (Int) -> Unit,
    val onRemoveTuplet: () -> Unit,
    val onToggleAddToChord: () -> Unit,
)

// MARK: Layouts

/**
 * Everything on one row, keys at their fixed minimum width and the three job groups (arm/re-time, navigate,
 * write) told apart by dividers — the single-row counterpart of [StackedRows]. Fixed widths are what makes this
 * layout measurable, so the caller can compare it against [SINGLE_ROW_MIN_WIDTH] before showing it.
 *
 * The grouping is the same in both layouts, deliberately: iOS's own single row moves the tie key away from the
 * durations and down beside the delete key, which leaves the same key in a different group depending on how wide
 * the window is. Keeping one grouping means a user who rotates a tablet finds the keys re-flowed, not re-sorted.
 */
@Composable
private fun SingleRow(arming: PadArming, actions: PadActions, enabled: Boolean, typeface: Typeface) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(SINGLE_ROW_GAP),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ArmingKeys(arming, actions, enabled, typeface, isFlexible = false)
        PadDivider()
        PitchKeys(actions, enabled, isFlexible = false)
        RestKey(arming, actions, enabled, typeface, isFlexible = false)
    }
}

/** Two rows split by job, not by convenience: row 1 arms or re-times, row 2 navigates and writes. Keys share the
 * row's width instead of claiming a fixed minimum, so this layout cannot overflow by construction — on the
 * narrowest supported phone each key still lands around 30 dp wide, and the 48 dp row height keeps the touch
 * targets tall enough to hit (iOS's own stacked rows land at ~29 pt for the same reason). */
@Composable
private fun StackedRows(arming: PadArming, actions: PadActions, enabled: Boolean, typeface: Typeface) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ArmingKeys(arming, actions, enabled, typeface, isFlexible = true)
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

/** Everything that arms or re-times what the NEXT note will be, in iOS's own row-1 order
 * (`EditorPadView.stackedRows`): the durations, the tuplet key, the tie key, the dot key — with the add-to-chord
 * arm appended, since iOS surfaces no key for it at all and it belongs with the other arms rather than among the
 * keys that write. */
@Composable
private fun RowScope.ArmingKeys(
    arming: PadArming,
    actions: PadActions,
    enabled: Boolean,
    typeface: Typeface,
    isFlexible: Boolean,
) {
    DurationKeys(arming, actions, enabled, typeface, isFlexible)
    TupletKey(arming, actions, enabled, isFlexible)
    TieKey(arming, actions, enabled, typeface, isFlexible)
    DotKey(arming, actions, enabled, isFlexible)
    AddToChordKey(arming, actions, enabled, typeface, isFlexible)
}

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

/**
 * The tuplet key: a tap turns the caret's slot into a tuplet of the armed size, or takes it back out of one —
 * the capsule shows which. It sits with the durations because a tuplet is a duration decision: it re-times the
 * slots the duration keys just set, and (like them) it acts on the CARET, which is why it reads
 * [PadArming.isCaretInTuplet] rather than anything about the selection.
 *
 * The sizes live behind a long press, reusing [DotKey]'s pattern rather than inventing a second one — iOS spells
 * the same thing as a `Menu` with `primaryAction:` (`EditorPadView.tripletKey`). The key then WEARS the last
 * size picked ([PadArming.armedTuplet], which the shared core remembers even when the edit itself is refused),
 * because a piece that wants quintuplets wants them more than once and shouldn't need the menu each time.
 */
@Composable
private fun RowScope.TupletKey(arming: PadArming, actions: PadActions, enabled: Boolean, isFlexible: Boolean) {
    var expanded by remember { mutableStateOf(false) }
    // The projection is the only writer of `armedTuplet`, and the core never publishes a size below 2 — but the
    // key wears this number and passes it straight to `createTuplet`, which refuses anything smaller, so a
    // degenerate value must not become a lit key that silently does nothing.
    val size = arming.armedTuplet.coerceAtLeast(TUPLET_SIZES.first())
    Box(keyWidth(isFlexible)) {
        PadKey(
            onClick = { if (arming.isCaretInTuplet) actions.onRemoveTuplet() else actions.onCreateTuplet(size) },
            onLongClick = { expanded = true },
            enabled = enabled,
            contentDescription = stringResource(R.string.reader_editing_tuplet),
            isArmed = arming.isCaretInTuplet,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("$size", fontWeight = FontWeight.SemiBold, color = keyContentColor(enabled))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            TUPLET_SIZES.forEach { choice ->
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.reader_editing_tuplet_count, choice)) },
                    onClick = {
                        actions.onCreateTuplet(choice)
                        expanded = false
                    },
                )
            }
        }
    }
}

/**
 * The tie key — one key carrying both halves of what iOS splits across two surfaces.
 *
 * iOS has a tie key on the pad that only ever APPENDS (`EditorContextOps.TieButton`: write the armed length into
 * the next slot at the same pitch and tie the two, hence the ＋ badge) and a second one in the selection callout
 * that only ever TOGGLES the tie to an existing same-pitch neighbour (`EditorCalloutView.tieKey`, lit while the
 * tie is there). Android's callout draws no tie key, so folding the two into this one is what makes ties
 * reachable at all — and the two meanings never compete, because they apply in mutually exclusive situations:
 * `canTie` needs a same-pitch note in the next slot, `canAppendTiedNote` needs an empty rest there.
 *
 * So: lit (and untying) when the selection is already tied, tying when there is a neighbour to tie to, and
 * appending — badged ＋, exactly as iOS badges its pad key — when there is only a rest to write into. Disabled
 * when neither is possible, per the file's own rule that a key which cannot act is drawn disabled rather than
 * left out.
 */
@Composable
private fun RowScope.TieKey(
    arming: PadArming,
    actions: PadActions,
    enabled: Boolean,
    typeface: Typeface,
    isFlexible: Boolean,
) {
    // `canTie` first: with a same-pitch note already in the next slot there is nothing to append into, and the
    // core's own `appendTiedNote` would refuse. The ＋ badge therefore shows exactly when this key writes a note.
    val ties = arming.canTie
    val tieEnabled = enabled && (ties || arming.canAppendTiedNote)
    PadKey(
        onClick = { if (ties) actions.onToggleTie() else actions.onAppendTiedNote() },
        enabled = tieEnabled,
        contentDescription = stringResource(R.string.reader_editing_tie),
        isArmed = arming.isSelectionTied,
        modifier = keyWidth(isFlexible),
    ) {
        Box(contentAlignment = Alignment.Center) {
            TieGlyph(typeface, tieEnabled)
            if (!ties) AddBadge(tieEnabled)
        }
    }
}

/**
 * The add-to-chord key: an ARM, not an action — while it is lit, the next pitch key adds to the selected chord
 * instead of replacing the selection, and the shared core clears the arm as soon as that note lands. It lights
 * with the same accent capsule the duration keys use, because it is the same kind of state.
 *
 * iOS has no key for this at all (`EditorContextOps`' doc: ＋音 / −音 are "out of the UI entirely", the commands
 * kept alive for a view-only re-surfacing). This is that re-surfacing, on the platform whose pad had the row for
 * it — with only the ARM offered, not the ＋音 / −音 pair: removing a note from a chord is a selection-scoped
 * edit and belongs to the callout, which is where iOS would put it too.
 */
@Composable
private fun RowScope.AddToChordKey(
    arming: PadArming,
    actions: PadActions,
    enabled: Boolean,
    typeface: Typeface,
    isFlexible: Boolean,
) {
    PadKey(
        onClick = actions.onToggleAddToChord,
        enabled = enabled,
        contentDescription = stringResource(R.string.reader_editing_add_to_chord),
        isArmed = arming.isAddToChordArmed,
        modifier = keyWidth(isFlexible),
    ) {
        Box(contentAlignment = Alignment.Center) {
            ChordGlyph(typeface, enabled)
            AddBadge(enabled)
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

/** `internal` (not `private`) so `EditingCallout.kt`'s own dot key — a selection-scoped counterpart to
 * [DotKey], since the callout re-times what's already written rather than arming what comes next — can offer
 * the same 1/2/3 choices instead of a second copy of this list. */
internal val DOT_CHOICES = listOf(
    1 to R.string.reader_editing_dot_single,
    2 to R.string.reader_editing_dot_double,
    3 to R.string.reader_editing_dot_triple,
)

/** The tuplet sizes [TupletKey]'s long-press menu offers, matching iOS's `EditorPadView.tupletSizes`. 7 and up
 * are vanishingly rare in the parts this edits and would only make the menu longer to read. */
private val TUPLET_SIZES = (2..6).toList()

/** `internal` (not `private`) so `PadSingleRowWidthTest` can pin [SINGLE_ROW_KEY_COUNT] against this list's real
 * size rather than a copy of "7". */
internal val PITCH_LETTERS = listOf('C', 'D', 'E', 'F', 'G', 'A', 'B')

// MARK: One key

/** One pad key's surface: fixed size, rounded, an accent capsule while [isArmed], and press feedback via the
 * platform's default ripple. [enabled] gates the click (through `combinedClickable`, which — unlike a stock
 * Material `Button` — applies NO dimming of its own) and is otherwise left to [content] to read for its own
 * color, exactly as iOS's `PadKeyChrome` pins every key's foreground to `.primary` / `.tertiary` off the same
 * `isEnabled` value rather than layering a second, container-level fade on top.
 *
 * `internal` (not `private`), along with [MusicGlyph], [keyContentColor], [DotsGlyph], [PadDivider] and
 * [DOT_CHOICES] below — the callout (`EditingCallout.kt`, Task 8) draws its own keys with this same chrome
 * rather than a second copy of it, exactly as iOS's `EditorCalloutView` reuses `PadKeyStyle`/`PadKeyGlyph` from
 * the pad it sits beside. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun PadKey(
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
internal fun keyContentColor(enabled: Boolean): Color =
    if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)

/** A duration/rest key's glyph, drawn through a native `Canvas`/`Paint` rather than Compose `Text` — see
 * `rememberBravuraTypeface`'s doc for why — and centered on the box by deriving the baseline from
 * [Paint.getFontMetrics], the same technique `DisplayInspectorSheet`'s `ClefTile` uses for the same font.
 *
 * Centering on the font's metrics rather than on each glyph's own ink is what keeps a ROW of these aligned: every
 * note lands on one shared baseline, so the whole note and the flagged 16th sit at the same height instead of
 * each being individually centered. A glyph that has to be centered on its own ink (the tie's arc, which lives
 * nowhere near the baseline) uses [MusicGlyphInkCentered] instead. */
@Composable
internal fun MusicGlyph(char: Char, typeface: Typeface, enabled: Boolean, modifier: Modifier = Modifier) {
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

/**
 * One music glyph centered on its own INK box rather than on the font's line metrics, at a caller-chosen
 * [textSize] that is independent of the box it is drawn into.
 *
 * Both halves exist for the tie key. `articLaissezVibrerAbove` is a thin arc about a third of an em wide, so at
 * the duration keys' glyph size it draws a hairline the width of a notehead and reads as a smudge — iOS sizes its
 * copy at 54 pt against the notes' 20 pt for exactly this reason (`PadKeyGlyph.tieSize`). And the arc sits well
 * above the baseline, so metric centering (which is what keeps a row of NOTES aligned, see [MusicGlyph]) would
 * push it off the key entirely once enlarged. iOS solves the same problem by trimming the line box against the
 * glyph's own band (`PadDurationGlyph.lineTrim`); [Paint.getTextBounds] is the same measurement.
 */
@Composable
private fun MusicGlyphInkCentered(
    char: Char,
    typeface: Typeface,
    enabled: Boolean,
    textSize: Dp,
    modifier: Modifier = Modifier,
) {
    val colorArgb = keyContentColor(enabled).toArgb()
    Canvas(modifier.size(GLYPH_SIZE)) {
        val paint = Paint().apply {
            isAntiAlias = true
            this.typeface = typeface
            this.textSize = textSize.toPx()
            color = colorArgb
            textAlign = Paint.Align.LEFT
        }
        val text = char.toString()
        val ink = Rect()
        paint.getTextBounds(text, 0, text.length, ink)
        drawIntoCanvas {
            // `ink` is measured from the drawing origin (left edge, baseline), so subtracting its own centre from
            // the box's centre is what puts the mark — not the font's notion of a line — in the middle.
            it.nativeCanvas.drawText(
                text,
                size.width / 2f - ink.exactCenterX(),
                size.height / 2f - ink.exactCenterY(),
                paint,
            )
        }
    }
}

/** The tie key's curve. See [MusicGlyphInkCentered] for why it is drawn at its own, much larger size. */
@Composable
private fun TieGlyph(typeface: Typeface, enabled: Boolean, modifier: Modifier = Modifier) {
    MusicGlyphInkCentered(MusicGlyphs.TIE, typeface, enabled, TIE_GLYPH_SIZE, modifier)
}

/**
 * Two stacked noteheads — a third, the smallest interval an engraver draws vertically — as the add-to-chord
 * key's mark. Drawn from the score's own `noteheadBlack` rather than a Material icon so the key reads as part of
 * the same family as the duration and rest keys beside it; there is no iOS glyph to mirror here, because iOS
 * surfaces no add-to-chord key at all (see [AddToChordKey]).
 *
 * The pair is offset by one staff space either side of the shared baseline. A staff space is a quarter of an em
 * in SMuFL, so it is derived from the text size rather than hand-picked — the same relationship the engraving
 * itself uses, which is what makes the two heads sit a third apart instead of an arbitrary distance.
 */
@Composable
private fun ChordGlyph(typeface: Typeface, enabled: Boolean, modifier: Modifier = Modifier) {
    val colorArgb = keyContentColor(enabled).toArgb()
    Canvas(modifier.size(GLYPH_SIZE)) {
        val textSize = GLYPH_SIZE.toPx()
        val paint = Paint().apply {
            isAntiAlias = true
            this.typeface = typeface
            this.textSize = textSize
            color = colorArgb
            textAlign = Paint.Align.CENTER
        }
        val head = MusicGlyphs.NOTEHEAD_BLACK.toString()
        val ink = Rect()
        paint.getTextBounds(head, 0, head.length, ink)
        // Centre the PAIR on the box: one head's ink centred, then each head moved half a staff space out.
        val center = size.height / 2f - ink.exactCenterY()
        val halfSpace = textSize * SMUFL_STAFF_SPACE_EM / 2f
        drawIntoCanvas {
            it.nativeCanvas.drawText(head, size.width / 2f, center - halfSpace, paint)
            it.nativeCanvas.drawText(head, size.width / 2f, center + halfSpace, paint)
        }
    }
}

/** The ＋ a key wears when tapping it WRITES something rather than toggling what is already there — the same
 * distinction iOS's `PadKeyGlyph.tie(showsAddBadge:)` draws, and the same mark (a filled plus-in-a-circle) it
 * uses for it. Parked at the top-trailing corner of the glyph it badges. */
@Composable
private fun AddBadge(enabled: Boolean) {
    Icon(
        Icons.Filled.AddCircle,
        contentDescription = null,
        tint = keyContentColor(enabled),
        modifier = Modifier
            .size(BADGE_SIZE)
            .offset(x = GLYPH_SIZE / 2 - BADGE_SIZE / 3, y = -(GLYPH_SIZE / 2) + BADGE_SIZE / 3),
    )
}

/** [count] filled dots in a row, and a single (unfilled-looking, since [keyContentColor] already carries the
 * enabled dimming) one when [count] is 0 — the key has to show what it offers even when it's off. Drawn as
 * shapes rather than `MusicGlyphs.AUGMENTATION_DOT`; see that constant's doc for why. */
@Composable
internal fun DotsGlyph(count: Int, enabled: Boolean, modifier: Modifier = Modifier) {
    val color = keyContentColor(enabled)
    val shown = count.coerceAtLeast(1)
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(DOT_GAP)) {
        repeat(shown) {
            Box(Modifier.size(DOT_DIAMETER).background(color, CircleShape))
        }
    }
}

/** The divider separating the pad's job groups (arm/re-time, navigate, write). */
@Composable
internal fun PadDivider() {
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
private val TIE_GLYPH_SIZE: Dp = 54.dp
private val BADGE_SIZE: Dp = 12.dp
private val DIVIDER_HEIGHT: Dp = 28.dp
private val DIVIDER_LINE_WIDTH: Dp = 1.dp
private val DIVIDER_HORIZONTAL_PADDING: Dp = 2.dp
private val DOT_DIAMETER: Dp = 4.dp
private val DOT_GAP: Dp = 3.dp

/** A staff space as a fraction of an em, which is how SMuFL defines every glyph it draws: an em is four staff
 * spaces. Used to space the chord glyph's two noteheads. */
private const val SMUFL_STAFF_SPACE_EM = 0.25f

/** A key's fixed width on the single-row layout. `internal` (not `private`) so `PadSingleRowWidthTest` can pin
 * [SINGLE_ROW_MIN_WIDTH] against the exact value [SingleRow] uses, not a second copy of the number. */
internal val KEY_MIN_WIDTH: Dp = 44.dp

/** The gap `SingleRow`'s own `Arrangement.spacedBy` uses — `internal` for the same reason as [KEY_MIN_WIDTH]. */
internal val SINGLE_ROW_GAP: Dp = 6.dp

/** [PadDivider]'s total footprint on the row: the line's own width plus the padding wrapped around both sides
 * of it (see [PadDivider]) — what a fixed-width sibling actually costs the row, not just the line's width. */
internal val DIVIDER_FOOTPRINT_WIDTH: Dp = DIVIDER_LINE_WIDTH + DIVIDER_HORIZONTAL_PADDING * 2

/** How many [PadDivider]s [SingleRow] lays out — one between each pair of its two job groups. Counted here
 * rather than assumed, because [singleRowRequiredWidthDp] has to bill for every one of them. */
internal const val SINGLE_ROW_DIVIDER_COUNT = 1

/**
 * How many individual keys [SingleRow] lays out today: [PadDuration.ordered]'s duration keys, the tuplet, tie,
 * dot and add-to-chord keys, the seven [PITCH_LETTERS] pitch keys, and the rest key — the same counts
 * [ArmingKeys]/[PitchKeys]/[RestKey] actually emit, not a copy of the number.
 * Anyone adding a key to [SingleRow] must add its count here too, or this value silently undercounts exactly as
 * [SINGLE_ROW_MIN_WIDTH] once did.
 */
internal val SINGLE_ROW_KEY_COUNT: Int
    get() = PadDuration.ordered.size + ARMING_EXTRA_KEY_COUNT + PITCH_LETTERS.size + 1

/** The arming group's non-duration keys: tuplet, tie, dot, add-to-chord. */
private const val ARMING_EXTRA_KEY_COUNT = 4

/**
 * Below this measured width the single row does not fit — see the class doc for why that has to be measured
 * rather than read off the window-size class.
 *
 * **Derived, not hand-picked.** [SingleRow] lays out [SINGLE_ROW_KEY_COUNT] keys at [KEY_MIN_WIDTH] plus
 * [SINGLE_ROW_DIVIDER_COUNT] dividers at [DIVIDER_FOOTPRINT_WIDTH], all separated by [SINGLE_ROW_GAP] —
 * `Arrangement.spacedBy` puts a gap between every pair of ADJACENT children, so `(children - 1)` gaps.
 * [singleRowRequiredWidthDp] is that arithmetic, pulled out into a plain function so `PadSingleRowWidthTest` can
 * pin it without a Compose/Robolectric dependency.
 *
 * A hand-computed constant here previously undercounted the row (640.dp against an actual ~705.dp requirement,
 * caught in review) — any measured card width in that gap picked the single-row layout and it ran off the card,
 * unscrollable and unclipped. Deriving this from the same values [SingleRow] uses is what makes that class of
 * bug impossible rather than merely fixed once: the keys added since (tuplet, tie, add-to-chord, the two
 * steppers) moved the threshold on their own, with nothing to update by hand.
 */
internal val SINGLE_ROW_MIN_WIDTH: Dp
    get() = singleRowRequiredWidthDp(
        keyCount = SINGLE_ROW_KEY_COUNT,
        keyWidthDp = KEY_MIN_WIDTH.value,
        gapDp = SINGLE_ROW_GAP.value,
        dividerFootprintDp = DIVIDER_FOOTPRINT_WIDTH.value,
        dividerCount = SINGLE_ROW_DIVIDER_COUNT,
    ).dp

/**
 * The width (in dp magnitude, not [Dp]) that [SingleRow] needs to lay out [keyCount] fixed-width keys plus
 * [dividerCount] dividers, all separated by [gapDp] gaps. Plain `Float` arithmetic rather than [Dp] so it has no
 * Compose-runtime dependency and `PadSingleRowWidthTest` can call it directly from a plain JVM test (this
 * module's unit tests have no Robolectric — see the module's other tests for why).
 */
internal fun singleRowRequiredWidthDp(
    keyCount: Int,
    keyWidthDp: Float,
    gapDp: Float,
    dividerFootprintDp: Float,
    dividerCount: Int,
): Float {
    val childCount = keyCount + dividerCount
    val gapCount = childCount - 1
    return keyCount * keyWidthDp + dividerCount * dividerFootprintDp + gapCount * gapDp
}

// MARK: Previews

@Preview(name = "Editing pad - stacked (360 dp)", showBackground = true)
@Composable
private fun EditingPadStackedPreview() {
    Box(Modifier.width(360.dp).padding(8.dp)) {
        PreviewPad(armedDurationKind = 3, armedDots = 1, canTie = true, isSelectionTied = true)
    }
}

/**
 * 680 dp: inside the old, hand-picked `SINGLE_ROW_MIN_WIDTH` (640.dp) but under the row's real requirement (see
 * [SINGLE_ROW_MIN_WIDTH]'s doc) — exactly the gap that once ran the single row off the card. Now that the
 * threshold is derived rather than hand-picked, this width falls below it and renders stacked; if it ever
 * renders single-row and overflows again, this is the preview that would show it.
 */
@Preview(name = "Editing pad - guard band (680 dp)", showBackground = true)
@Composable
private fun EditingPadGuardBandPreview() {
    Box(Modifier.width(680.dp).padding(8.dp)) {
        PreviewPad(armedDurationKind = 3, canAppendTiedNote = true)
    }
}

@Preview(name = "Editing pad - single row (1100 dp)", showBackground = true, widthDp = 1100)
@Composable
private fun EditingPadSingleRowPreview() {
    Box(Modifier.width(1100.dp).padding(8.dp)) {
        PreviewPad(armedDurationKind = 4, canWriteRest = false, isCaretInTuplet = true, armedTuplet = 5)
    }
}

@Preview(name = "Editing pad - chord armed", showBackground = true)
@Composable
private fun EditingPadChordArmedPreview() {
    Box(Modifier.width(360.dp).padding(8.dp)) {
        PreviewPad(armedDurationKind = 3, isAddToChordArmed = true, canAppendTiedNote = true)
    }
}

@Preview(name = "Editing pad - inert (no edit target)", showBackground = true)
@Composable
private fun EditingPadInertPreview() {
    Box(Modifier.width(360.dp).padding(8.dp)) {
        PreviewPad(hasEditTarget = false, canWriteRest = false)
    }
}

/** The previews' shared call, so each one names only the state it is there to show. */
@Composable
private fun PreviewPad(
    armedDurationKind: Int = 0,
    armedDots: Int = 0,
    canWriteRest: Boolean = true,
    canTie: Boolean = false,
    isSelectionTied: Boolean = false,
    canAppendTiedNote: Boolean = false,
    isCaretInTuplet: Boolean = false,
    armedTuplet: Int = DEFAULT_TUPLET_SIZE,
    isAddToChordArmed: Boolean = false,
    hasEditTarget: Boolean = true,
) {
    EditingPad(
        armedDurationKind = armedDurationKind,
        armedDots = armedDots,
        canWriteRest = canWriteRest,
        canTie = canTie,
        isSelectionTied = isSelectionTied,
        canAppendTiedNote = canAppendTiedNote,
        isCaretInTuplet = isCaretInTuplet,
        armedTuplet = armedTuplet,
        isAddToChordArmed = isAddToChordArmed,
        hasEditTarget = hasEditTarget,
        isPlaybackActive = false,
        onArmDuration = {},
        onSetArmedDots = {},
        onToggleArmedDot = {},
        onInputPitch = {},
        onWriteRest = {},
        onToggleTie = {},
        onAppendTiedNote = {},
        onCreateTuplet = {},
        onRemoveTuplet = {},
        onToggleAddToChord = {},
    )
}
