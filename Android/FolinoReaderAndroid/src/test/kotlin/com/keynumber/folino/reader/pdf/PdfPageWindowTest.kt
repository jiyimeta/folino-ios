package com.keynumber.folino.reader.pdf

import org.junit.Assert.assertEquals
import org.junit.Test

class PdfPageWindowTest {
    @Test fun windowIsCenteredInTheMiddleOfADocument() {
        assertEquals(3..7, PdfPageWindow.range(current = 5, pageCount = 20, radius = 2))
    }

    @Test fun windowClampsAtTheStart() {
        assertEquals(0..2, PdfPageWindow.range(current = 0, pageCount = 20, radius = 2))
    }

    @Test fun windowClampsAtTheEnd() {
        assertEquals(17..19, PdfPageWindow.range(current = 19, pageCount = 20, radius = 2))
    }

    @Test fun windowNeverExceedsAShortDocument() {
        assertEquals(0..1, PdfPageWindow.range(current = 1, pageCount = 2, radius = 5))
    }

    @Test fun emptyDocumentYieldsAnEmptyRange() {
        assertEquals(IntRange.EMPTY, PdfPageWindow.range(current = 0, pageCount = 0, radius = 2))
    }
}
