package com.keynumber.folino.reader.pdf

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfRenderInstallTest {
    @Test fun matchingGenerationAndWidthInstalls() {
        assertTrue(
            PdfRenderInstall.canInstall(
                generation = 1,
                widthPx = 800,
                cachedGeneration = 1,
                cachedWidthPx = 800,
                closed = false,
            ),
        )
    }

    @Test fun staleGenerationDiscards() {
        // The slot was evicted (e.g. by setWindow) and recreated for the same index before this render
        // finished — its generation moved on even though the width still matches.
        assertFalse(
            PdfRenderInstall.canInstall(
                generation = 1,
                widthPx = 800,
                cachedGeneration = 2,
                cachedWidthPx = 800,
                closed = false,
            ),
        )
    }

    @Test fun supersededWidthDiscards() {
        // The same slot (same generation) moved on to a different requested width before this render
        // for the old width finished.
        assertFalse(
            PdfRenderInstall.canInstall(
                generation = 1,
                widthPx = 800,
                cachedGeneration = 1,
                cachedWidthPx = 1200,
                closed = false,
            ),
        )
    }

    @Test fun closedSourceDiscardsEvenOnAnExactMatch() {
        assertFalse(
            PdfRenderInstall.canInstall(
                generation = 1,
                widthPx = 800,
                cachedGeneration = 1,
                cachedWidthPx = 800,
                closed = true,
            ),
        )
    }
}
