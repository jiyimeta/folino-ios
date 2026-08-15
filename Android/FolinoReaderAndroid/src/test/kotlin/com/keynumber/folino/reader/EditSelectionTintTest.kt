package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.RestID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.SelectionTint
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.SelectionTintCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [selectionTintPayload] — the one part of `ReaderViewModel.setEditSelection` that can be pinned off-device.
 *
 * This module's JVM test source set has no Robolectric and no Android `Application` (see `RecomputeSkipTest` and
 * `ReaderEditHostTest` for the same constraint), so a [ReaderViewModel] cannot be constructed here at all and the
 * native call itself has no JNI library to reach. What is left, and what actually goes wrong silently, is the
 * PAYLOAD: `nativeEncodeDrawProgram` decodes these bytes on the Swift side, and a tint that packs its color or its
 * item set wrongly recolors the wrong notes with nothing at runtime noticing.
 *
 * The property `setEditSelection` also has to hold — that it re-encodes without ever laying out again — is
 * STRUCTURAL, not behavioral: the function calls `nativeEncodeDrawProgram` and never `nativeComputeLayout`, and
 * `layoutGeneration` has no assignment on that path. That is a review and device-pass concern; there is nothing a
 * JVM test could observe about it here.
 */
class EditSelectionTintTest {

    private val note = ScoreItemID.Note(
        NoteID(
            staff = StaffAddress(partIndex = 1, staffIndexInPart = 0),
            measureIndex = 4,
            voiceIndex = 0,
            elementIndex = 2,
            noteIndexInChord = 1,
        ),
    )

    private val rest = ScoreItemID.Rest(
        RestID(
            staff = StaffAddress(partIndex = 0, staffIndexInPart = 1),
            measureIndex = 7,
            voiceIndex = 1,
            elementIndex = 3,
        ),
    )

    /** The accent-tint value the golden corpus uses on both sides (`GoldenBinaryTests.canonicalTintArgb`). */
    private val argb = 0xFF3366CCu

    @Test
    fun `round-trips the selection the view model builds`() {
        val decoded = SelectionTintCodec.decode(selectionTintPayload(listOf(note, rest), argb))
        assertEquals(SelectionTint(argb = argb, items = listOf(note, rest)), decoded)
    }

    @Test
    fun `an empty selection encodes the payload that reproduces the untinted program`() {
        // ssm documents an empty selection as reproducing `nativeComputeLayout`'s bytes exactly, which is what makes
        // CLEARING the selection the same call as setting it. That only holds if an empty list really does encode as
        // an empty item set rather than, say, a payload that omits the field or smuggles a stale item through.
        val payload = selectionTintPayload(emptyList(), argb)
        val decoded = SelectionTintCodec.decode(payload)
        assertTrue("an empty selection must carry no items", decoded.items.isEmpty())
        assertEquals(SelectionTint(argb = argb, items = emptyList()), decoded)
    }

    @Test
    fun `decodes the selected item the session published`() {
        // The wiring's other half: `EditUiState.selectedItem` arrives as the raw wire and has to come back through
        // ssm's own codec, never a hand-rolled parse (see `decodeSelectedItems`'s doc).
        assertEquals(listOf(note), decodeSelectedItems(ScoreItemIDCodec.encode(note)))
        assertEquals(listOf(rest), decodeSelectedItems(ScoreItemIDCodec.encode(rest)))
    }

    @Test
    fun `no selection, an explicit deselect, and a corrupt blob all tint nothing`() {
        // Null is "nothing selected"; EMPTY is the shared core's explicit deselect (`EditorBridge.selectItem`), which
        // is what a tap on paper sends; garbage can only be a wire disagreement, and blanking the tint beats
        // crashing the Reader over a highlight.
        assertTrue(decodeSelectedItems(null).isEmpty())
        assertTrue(decodeSelectedItems(ByteArray(0)).isEmpty())
        assertTrue(decodeSelectedItems(byteArrayOf(0x7f, 0x7f, 0x7f, 0x7f)).isEmpty())
    }

    @Test
    fun `preserves an argb whose alpha byte sets the sign bit`() {
        // Every opaque color has its top bit set, so this is the ordinary case, not an edge one — but `argb` crosses
        // as a varint via `UInt.toLong()`, and the same value read back through a signed `Int` anywhere in that path
        // would come out negative and tint with a garbage color. Pin the widest one.
        val opaqueWhite = 0xFFFFFFFFu
        val decoded = SelectionTintCodec.decode(selectionTintPayload(listOf(note), opaqueWhite))
        assertEquals(opaqueWhite, decoded.argb)
    }
}
