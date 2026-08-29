package com.keynumber.folino.editor

/**
 * The one thing a save needs from whoever owns the library database: put the two columns a save derives back on the
 * score's row.
 *
 * An interface here rather than a dependency on `:FolinoLibraryAndroid` for the reason [EditSessionHost] is one — the
 * editor module is a sibling of the library module, not a consumer of it, and `:app` is the layer that sees both. It
 * binds this to `RoomLibraryStore.refreshRowAfterSave`.
 *
 * **A partial update of exactly these columns, never a whole-row write.** `EditorBridge.stubRowPendingSave` builds
 * the `ScoreItem` an Android session carries with only `id` and `localFileName` real, and
 * `EditorSessionCore.performSave` rebuilds the row from every field of it — so a whole-row Android writer would push
 * those placeholders over the user's real title, tags and dates. The stub and this narrowness are one safety; do not
 * widen either without the other.
 *
 * Two values, not three: iOS also refreshes `sizeBytes`, and Android's `score_records` has no such column and nothing
 * that reads a size. Adding one for a value nobody reads would cost a real migration on a shipped schema.
 */
fun interface ScoreRowRefreshing {
    /**
     * @param id the score's row id (the `ScoreItemID` UUID string the session was opened with).
     * @param localFileName the file the score now lives in — different from the one it opened with exactly when a
     *   non-MuseScore source was saved as a sibling `.mscz`.
     * @param contentHash lowercase hex SHA-256 of that file, in the format the importer writes.
     */
    fun refreshAfterSave(id: String, localFileName: String, contentHash: String)
}
