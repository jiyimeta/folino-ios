package com.keynumber.folino.reader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the pure [shouldSkipLayoutRecompute] predicate — the gate that keeps
 * `ReaderViewModel`'s layout recompute loop from ever computing a DrawProgram for a PDF's
 * background-parsed score (Task 12). This is the regression guard for the highest-value fix in that
 * task: without it, the loop would overwrite `ReaderState.ReadyPdf` with `Ready(program)` the instant a
 * PDF's OMR parse succeeded, silently swapping the user's own PDF pages for reconstructed notation.
 */
class RecomputeSkipTest {

    @Test fun noScoreHandle_skips() {
        assertTrue(shouldSkipLayoutRecompute(scoreHandle = null, layoutWidthMm = 100.0, isPdfPlaybackReady = false))
    }

    @Test fun noLayoutWidth_skips() {
        assertTrue(shouldSkipLayoutRecompute(scoreHandle = 1L, layoutWidthMm = null, isPdfPlaybackReady = false))
    }

    @Test fun pdfPlaybackReady_skipsEvenWithHandleAndWidth() {
        // THE regression guard: a PDF's parsed score publishes into the same `scoreHandle` a `.mscz`
        // score would, and by the time it's Ready the viewport has long since reported a width — so
        // only this flag stands between the loop and clobbering ReaderState.ReadyPdf.
        assertTrue(shouldSkipLayoutRecompute(scoreHandle = 1L, layoutWidthMm = 100.0, isPdfPlaybackReady = true))
    }

    @Test fun mszScore_handleAndWidthPresent_notPdfPlayback_doesNotSkip() {
        assertFalse(shouldSkipLayoutRecompute(scoreHandle = 1L, layoutWidthMm = 100.0, isPdfPlaybackReady = false))
    }

    @Test fun everythingMissing_skips() {
        assertTrue(shouldSkipLayoutRecompute(scoreHandle = null, layoutWidthMm = null, isPdfPlaybackReady = true))
    }
}
