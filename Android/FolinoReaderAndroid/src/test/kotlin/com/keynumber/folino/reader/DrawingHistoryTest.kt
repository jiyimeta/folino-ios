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
}
