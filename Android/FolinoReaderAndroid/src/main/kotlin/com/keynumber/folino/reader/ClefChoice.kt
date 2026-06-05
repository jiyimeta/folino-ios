package com.keynumber.folino.reader

/**
 * Per-staff clef-override choices for the Reader display inspector, mirroring iOS
 * ClefMenuChoice. [glyph] is a SMuFL Bravura Private-Use-Area codepoint rendered
 * with the bundled music font. [rawType] is the NotatedClef rawType stored in the
 * override map. The four C-clef variants share the movable cClef glyph (U+E05C);
 * their staff-line position is what distinguishes them.
 */
enum class ClefChoice(val rawType: String, val glyph: Int, val label: String) {
    TREBLE_G("G", 0xE050, "Treble"),
    TREBLE_G8VA("G8va", 0xE053, "Treble 8va"),
    TREBLE_G8VB("G8vb", 0xE052, "Treble 8vb"),
    TREBLE_G15MA("G15ma", 0xE054, "Treble 15ma"),
    TREBLE_G15MB("G15mb", 0xE051, "Treble 15mb"),
    BASS_F("F", 0xE062, "Bass"),
    BASS_F8VA("F8va", 0xE065, "Bass 8va"),
    BASS_F8VB("F8vb", 0xE064, "Bass 8vb"),
    SOPRANO_C1("C1", 0xE05C, "Soprano"),
    ALTO_C3("C3", 0xE05C, "Alto"),
    TENOR_C4("C4", 0xE05C, "Tenor"),
    BARITONE_C5("C5", 0xE05C, "Baritone"),
    PERCUSSION("PERC", 0xE069, "Percussion"),
    PERCUSSION2("PERC2", 0xE06A, "Percussion (alt)");

    val isPercussion: Boolean get() = this == PERCUSSION || this == PERCUSSION2

    companion object {
        fun fromRawType(raw: String): ClefChoice? = entries.firstOrNull { it.rawType == raw }
        val trebleFamily = listOf(TREBLE_G, TREBLE_G8VA, TREBLE_G8VB, TREBLE_G15MA, TREBLE_G15MB)
        val bassFamily = listOf(BASS_F, BASS_F8VA, BASS_F8VB)
        val cFamily = listOf(SOPRANO_C1, ALTO_C3, TENOR_C4, BARITONE_C5)
        val percussionFamily = listOf(PERCUSSION, PERCUSSION2)
    }
}
