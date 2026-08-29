package com.keynumber.folino.editor

/**
 * An [EditAutosave] that writes nothing, for the suites whose subject is the MIRROR rather than the file.
 *
 * [EditSessionParityTest] and [EditingUiTest] assert on fingerprints and on projected UI state, and a save landing
 * in the middle of either is noise at best. It is also what keeps
 * `EditSessionParityTest.reopeningAfterAnUnsavedEditResyncsInsteadOfDiverging` meaningful: that test needs a session
 * to close WITHOUT persisting, so the second one parses a file the first one's edits never reached — the state
 * `open()`'s fingerprint check exists to catch, and one that production now reaches only when a save has failed.
 *
 * `EditPersistenceTest` is the deliberate exception; it uses the real [DebouncedAutosave], because there the save
 * path is the subject.
 */
object NoAutosave : EditAutosave {
    override fun arm() {}
    override fun flushNow() {}
    override fun cancel() {}
}
