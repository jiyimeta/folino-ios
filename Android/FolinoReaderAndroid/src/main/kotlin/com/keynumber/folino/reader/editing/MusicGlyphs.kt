package com.keynumber.folino.reader.editing

import android.graphics.Typeface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.keynumber.folino.reader.R

/**
 * SMuFL codepoints for the note-editing UI, and the Bravura typeface they are drawn with.
 *
 * Bravura is the score's own engraving font — Compose renders the same face from the same numbers as iOS's
 * `EditorCore.PadGlyphs`, the canonical table this one mirrors codepoint for codepoint. The v1 stand-ins were
 * Unicode's Musical Symbols block (U+1D15D…) drawn with the system font, and every one of them rendered as a
 * `.notdef` box: no platform font covers that block, and several of those codepoints are canonical
 * *decompositions* (notehead + combining stem + combining flag), so a single key could draw two or three boxes
 * and push a row past its edge. Whichever platform renders these, that is the failure mode to watch for — pin
 * against the codepoints iOS already validated, not a lookalike block.
 */
object MusicGlyphs {
    // The duration note glyphs ("note with upward stem"), longest value first — the order the pad's duration keys
    // appear in. All align on their noteheads at the text baseline.
    const val NOTE_WHOLE = '\uE1D2' // noteWhole
    const val NOTE_HALF_UP = '\uE1D3' // noteHalfUp
    const val NOTE_QUARTER_UP = '\uE1D5' // noteQuarterUp
    const val NOTE_8TH_UP = '\uE1D7' // note8thUp
    const val NOTE_16TH_UP = '\uE1D9' // note16thUp

    // The rest counterparts. Whole and half take the LEGER-LINE variants rather than the bare glyphs: the two
    // rests are the same black rectangle and differ only by which side of a staff line they attach to, which a
    // bare key (no staff underneath it) can't show — these are the same glyphs MuseScore uses when a rest has to
    // carry its own line: whole below the line, half above it.
    const val REST_WHOLE_LEGER_LINE = '\uE4F4' // restWholeLegerLine — hangs under its line
    const val REST_HALF_LEGER_LINE = '\uE4F5' // restHalfLegerLine — sits on top of its line
    const val REST_QUARTER = '\uE4E5' // restQuarter
    const val REST_8TH = '\uE4E6' // rest8th
    const val REST_16TH = '\uE4E7' // rest16th
    const val REST_32ND = '\uE4E8' // rest32nd
    const val REST_64TH = '\uE4E9' // rest64th — also stands in for 128th/256th; see `PadDuration.restGlyph`.

    /** Bravura's own augmentation dot. Reserved rather than drawn: at pad-key size the font glyph is a ~1 pt
     * speck (0.1 em by design — an em is four staff spaces and a dot is 0.4 of one), so the dot key draws filled
     * circles instead (see `DotsGlyph` in `EditingPad.kt`). Kept here so this table stays a complete mirror of
     * iOS's `PadGlyphs`. */
    const val AUGMENTATION_DOT = '\uE1E7'

    /** The tie key's glyph — `articLaissezVibrerAbove`; SMuFL has no tie of its own, but a "let vibrate" mark IS
     * a tie curve with nothing on its far end. Not drawn yet: the pad's tie key is second-pass (writing it needs
     * `EditProjection.canAppendTiedNote`, which isn't projected into `EditUiState` yet). Kept here so the table
     * is ready when that lands. */
    const val TIE = '\uE4BA' // articLaissezVibrerAbove
}

/**
 * The bundled SMuFL music typeface (Bravura). The asset ships in the SheetMusicComposeAndroid dependency at
 * `fonts/Bravura.otf` and merges into the app's assets at build time, so this resolves it at runtime via the app
 * context's `AssetManager`. Returned as an `android.graphics.Typeface` — every call site here draws through a
 * native `Canvas`/`Paint` rather than Compose `Text`, because a music font's line-box metrics (ascent/descent) are
 * enormous relative to the ink it draws, the same problem iOS solves with `PadDurationGlyph.lineTrim`.
 *
 * Shared by the display inspector's clef tiles (`DisplayInspectorSheet.kt`) and the note-editing pad
 * (`EditingPad.kt`) — moved here from `DisplayInspectorSheet.kt` so both call sites resolve the same asset
 * through one function instead of each `Typeface.createFromAsset`-ing its own copy.
 */
@Composable
fun rememberBravuraTypeface(): Typeface {
    val context = LocalContext.current
    return remember(context) {
        Typeface.createFromAsset(context.assets, "fonts/Bravura.otf")
    }
}

/**
 * One pad duration key: the bridge's ARMING kind paired with the note/rest glyphs and the accessibility label the
 * key wears. `kind` is `NoteDurationWire`'s discriminator as `EditorBridge.armDuration(kind:)` decodes it (see
 * `PadDuration`'s doc for why that distinction matters), not an ordinal into this list.
 */
data class PadDurationEntry(
    val kind: Int,
    val noteGlyph: Char,
    val restGlyph: Char,
    val labelRes: Int,
)

/**
 * The pad's duration keys, and the rest-glyph lookup the ⌫ key uses.
 *
 * **`ordered`'s `kind` values are deliberately the ARMING vocabulary, not the emit vocabulary.**
 * `EditorBridge.armDuration(kind:)` decodes `NoteDurationWire`'s discriminator (1 = whole … 9 = 256th, 10 =
 * measure, 11 = fraction) through `duration(fromKind:)`, which has no `case` for kind 11 — `.fraction` is
 * emit-only — and silently no-ops for it. A pad key built from the emit-side numbering would be a dead key with
 * nothing to catch it; `PadDurationKindTest` pins this table against that exact mapping.
 *
 * Stops at the sixteenth (kind 5), mirroring iOS's `PadGlyphs.ordered`: 32nds and 64ths cost two keys out of a row
 * that already shares its width with the dot key, and they are rare enough in the parts this edits that the trade
 * isn't worth it. A score that already contains them still renders and arms fine — see `restGlyph` below.
 */
object PadDuration {
    val ordered: List<PadDurationEntry> = listOf(
        PadDurationEntry(
            1, MusicGlyphs.NOTE_WHOLE, MusicGlyphs.REST_WHOLE_LEGER_LINE, R.string.reader_editing_duration_whole,
        ),
        PadDurationEntry(
            2, MusicGlyphs.NOTE_HALF_UP, MusicGlyphs.REST_HALF_LEGER_LINE, R.string.reader_editing_duration_half,
        ),
        PadDurationEntry(
            3, MusicGlyphs.NOTE_QUARTER_UP, MusicGlyphs.REST_QUARTER, R.string.reader_editing_duration_quarter,
        ),
        PadDurationEntry(
            4, MusicGlyphs.NOTE_8TH_UP, MusicGlyphs.REST_8TH, R.string.reader_editing_duration_eighth,
        ),
        PadDurationEntry(
            5, MusicGlyphs.NOTE_16TH_UP, MusicGlyphs.REST_16TH, R.string.reader_editing_duration_sixteenth,
        ),
    )

    /**
     * The rest glyph for the currently armed [kind] — what the ⌫ key wears, since what that key does is turn a
     * note into a rest, so it shows the silence it's about to leave behind.
     *
     * Covers every kind `EditUiState.armedDurationKind` can carry, not just the five [ordered] has a key for:
     * arming from an existing selection (`armFromSelectionIfNeeded` on the Swift side) can land on a duration the
     * pad has no key for — a 32nd note, say — and the delete key still has to show the right rest for it rather
     * than a generic quarter. Mirrors iOS `PadGlyphs.rest(for:)` kind for kind, including its fallback: kind 0
     * (nothing armed yet) and kind 11 (`.fraction`, which a plain armed duration is never scaled/dotted enough to
     * be) both read as a quarter rest.
     */
    fun restGlyph(kind: Int): Char = when (kind) {
        1, 10 -> MusicGlyphs.REST_WHOLE_LEGER_LINE
        2 -> MusicGlyphs.REST_HALF_LEGER_LINE
        4 -> MusicGlyphs.REST_8TH
        5 -> MusicGlyphs.REST_16TH
        6 -> MusicGlyphs.REST_32ND
        7, 8, 9 -> MusicGlyphs.REST_64TH
        else -> MusicGlyphs.REST_QUARTER
    }
}
