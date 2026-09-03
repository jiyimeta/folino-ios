package com.keynumber.folino.reader

/**
 * What leaving an annotation session offers to do — the three-way answer the reader's session header renders in its
 * trailing slot.
 *
 * **The rule is not decided here.** `ReaderAnnotationCore.AnnotationSessionEndMode.derive` in shared Swift decides it
 * for both platforms, reached through [ReaderAnnotationJNI.sessionEndMode]; this enum only names the answer on the
 * Kotlin side. The ordinals are the wire contract with that Swift enum's `Int32` raw values, so the declaration order
 * is load-bearing — see [fromRawValue].
 *
 * * [COMMIT_UNCHANGED] — nothing has ever been drawn on this score. Leaving changes nothing, so the control is quiet.
 * * [COMMIT_EDITED] — this session put ink down or took it away. Leaving keeps it (it is already saved), and the
 *   control fills to say the score is not what it was when it was opened.
 * * [CLEAR_ALL] — this session changed nothing, but the score carries ink from before. The only thing worth offering
 *   is undoing that *previous* work: deleting every annotation on the score — the annotation layer's "revert to
 *   original", and the one destructive control in the header.
 */
enum class AnnotationSessionEndMode {
    COMMIT_UNCHANGED,
    COMMIT_EDITED,
    CLEAR_ALL,
    ;

    companion object {
        /**
         * Maps a raw value straight off the JNI boundary. An unrecognized value can only mean the `.so` and this
         * Kotlin disagree about the enum — a stale-artifact skew, not a user-reachable state — so it falls back to
         * the harmless case rather than throwing: a reader mid-session should get a plain "leave" control, not a
         * crash.
         */
        fun fromRawValue(raw: Int): AnnotationSessionEndMode =
            entries.getOrElse(raw) { COMMIT_UNCHANGED }
    }
}
