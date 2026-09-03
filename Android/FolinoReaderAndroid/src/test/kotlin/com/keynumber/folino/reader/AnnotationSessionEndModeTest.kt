package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The Kotlin half of the JNI wire contract for the annotation session's trailing control.
 *
 * WHICH control shows is not decided on this side at all — `ReaderAnnotationCore.AnnotationSessionEndMode.derive` in
 * shared Swift decides it for both platforms, and its own rules are covered by `AnnotationSessionEndModeTests` (the
 * Swift suite, which also pins the raw values these ordinals have to match). What CAN go wrong here, silently, is
 * the mapping: `nativeAnnotationSessionEndMode` returns a raw `Int` and nothing links the two enums, so a reordered
 * case would show the wrong control with no compile or link error anywhere. That is what this pins.
 *
 * `ReaderAnnotationJNI.sessionEndMode` itself is not exercised here: it loads `libFolinoReaderJNI.so`, which this
 * JVM test source set has no way to.
 */
class AnnotationSessionEndModeTest {
    @Test fun ordinalsMatchTheSwiftRawValues() {
        assertEquals(AnnotationSessionEndMode.COMMIT_UNCHANGED, AnnotationSessionEndMode.fromRawValue(0))
        assertEquals(AnnotationSessionEndMode.COMMIT_EDITED, AnnotationSessionEndMode.fromRawValue(1))
        assertEquals(AnnotationSessionEndMode.CLEAR_ALL, AnnotationSessionEndMode.fromRawValue(2))
    }

    /**
     * A value outside the enum can only mean the staged `.so` and this Kotlin were built from different sources — a
     * stale-artifact skew. A reader mid-session gets the harmless "just leave" control rather than an exception out
     * of composition.
     */
    @Test fun anUnknownRawValueFallsBackToTheQuietControl() {
        assertEquals(AnnotationSessionEndMode.COMMIT_UNCHANGED, AnnotationSessionEndMode.fromRawValue(3))
        assertEquals(AnnotationSessionEndMode.COMMIT_UNCHANGED, AnnotationSessionEndMode.fromRawValue(-1))
    }
}
