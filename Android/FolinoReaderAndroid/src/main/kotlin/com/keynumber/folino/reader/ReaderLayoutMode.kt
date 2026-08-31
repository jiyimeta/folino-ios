package com.keynumber.folino.reader

/**
 * Reader display mode, mirrored from the app-level `reader.layoutMode` pref
 * (Settings → Layout). The pref stores the iOS-parity raw strings
 * `"vertical" | "horizontal" | "page"`; [fromPref] maps them to this enum.
 *
 * All three have their own surface now (`ReadyScore`, `HorizontalScore`,
 * `PagedScore`), and all three read, play, annotate and edit. Keep this enum the
 * single branch point: `ReaderScreen`'s `when (layoutMode)` is the only place
 * that chooses between them.
 */
enum class ReaderLayoutMode {
    VERTICAL,
    HORIZONTAL,
    PAGE,
    ;

    companion object {
        /** Map a stored pref string to a mode, defaulting to [VERTICAL] for unknown values. */
        fun fromPref(value: String): ReaderLayoutMode = when (value) {
            "horizontal" -> HORIZONTAL
            "page" -> PAGE
            else -> VERTICAL
        }
    }
}
