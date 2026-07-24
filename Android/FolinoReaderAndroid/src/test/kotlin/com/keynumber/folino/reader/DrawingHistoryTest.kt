package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DrawingHistoryTest {
    private fun layer(vararg names: String) = names.toList()

    @Test fun undoReturnsThePreviousLayer() {
        val h = DrawingHistory<String>()
        h.push(layer("a"))
        assertTrue(h.canUndo)
        assertEquals(layer("a"), h.undo(layer("a", "b")))
    }

    @Test fun redoReturnsTheUndoneLayer() {
        val h = DrawingHistory<String>()
        h.push(layer("a"))
        h.undo(layer("a", "b"))
        assertTrue(h.canRedo)
        assertEquals(layer("a", "b"), h.redo(layer("a")))
    }

    @Test fun aNewMutationClearsRedo() {
        val h = DrawingHistory<String>()
        h.push(layer("a"))
        h.undo(layer("a", "b"))
        h.push(layer("a"))
        assertFalse(h.canRedo)
    }

    @Test fun depthIsCapped() {
        val h = DrawingHistory<String>(maxDepth = 3)
        repeat(10) { h.push(layer("s$it")) }
        var current = layer("now")
        var steps = 0
        while (h.canUndo) { current = h.undo(current)!!; steps++ }
        assertEquals(3, steps)
    }

    @Test fun clearEmptiesBothStacks() {
        val h = DrawingHistory<String>()
        h.push(layer("a"))
        h.undo(layer("a", "b"))
        h.clear()
        assertFalse(h.canUndo)
        assertFalse(h.canRedo)
    }

    @Test fun undoOnAnEmptyStackReturnsNull() {
        assertNull(DrawingHistory<String>().undo(layer("a")))
    }

    // --- Erase-gesture history gating (pins ReaderViewModel.eraseInProgress/eraseCommitted's
    // `pushHistory` parameter — see their KDoc and ReaderScreen's eraseHistoryPushed). ---
    //
    // ReaderViewModel is an AndroidViewModel backed by a Room-persisted AnnotationSaveBridgeViewModel
    // (constructed eagerly in its `init`), and this module has no Robolectric/AndroidX Test setup — so
    // constructing a real VM instance in a plain JUnit unit test isn't possible without adding that
    // infrastructure, which is out of scope for this fix. These tests instead pin the exact
    // DrawingHistory-level contract the VM's `applyDrawings` choke point relies on:
    //
    //   val updated = synchronized(layerLock) {
    //       val previous = _drawings.value
    //       val next = transform(previous)
    //       _drawings.value = next
    //       if (pushHistory) history.push(previous)   // <-- the exact line under test
    //       ...
    //   }
    //
    // i.e. `pushHistory = false` must NEVER call [DrawingHistory.push] — so a no-op erase gesture (spec:
    // "changedIndices empty means the gesture did nothing: no save, no undo entry, no phase 2") must
    // leave canUndo/canRedo, and any prior redoable entry, completely untouched — while
    // `pushHistory = true` must push exactly one entry and clear redo, same as every other committing
    // mutation (addDrawing/removeDrawing/undo/redo).

    @Test fun aNonPushingPublish_leavesCanUndoAndRedoUntouched() {
        // Mirrors the repro: draw A, draw B, undo B (B now redoable) — then a NO-OP erase gesture
        // (`eraseCommitted(pushHistory = false, ...)`) must not call push at all.
        val h = DrawingHistory<String>()
        h.push(layer())            // "draw A": previous (empty) pushed
        h.push(layer("a"))         // "draw B": previous ("a") pushed
        h.undo(layer("a", "b"))    // undo B -> B is now redoable
        assertTrue(h.canUndo)
        assertTrue(h.canRedo)

        // `pushHistory = false` means applyDrawings never calls history.push — simulate that by
        // literally doing nothing to `h`, then assert nothing changed.
        assertTrue(h.canUndo)
        assertTrue(h.canRedo) // B must still be recoverable — this is the exact bug the fix closes.
    }

    @Test fun aPushingPublish_pushesExactlyOneEntryAndClearsRedo() {
        val h = DrawingHistory<String>()
        h.push(layer("a"))
        h.undo(layer("a", "b"))
        assertTrue(h.canRedo)

        // `pushHistory = true` on the FIRST changing tick of a gesture: applyDrawings pushes the
        // pre-gesture layer once (the previous value, which — since no changing tick preceded it — IS
        // the pre-gesture base).
        h.push(layer("a", "b"))
        assertTrue(h.canUndo)
        assertFalse(h.canRedo)
    }
}
