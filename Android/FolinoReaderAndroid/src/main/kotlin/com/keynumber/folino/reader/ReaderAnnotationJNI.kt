package com.keynumber.folino.reader

import com.keynumber.folino.reader.swiftjava.Data as SwiftData
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI as SwiftJavaJNI
import org.swift.swiftkit.core.SwiftMemoryManagement

/**
 * Kotlin facade over the FolinoReaderJNI freehand-annotation bridge. Byte plumbing only — the anchoring math lives in
 * shared Swift (`AnnotationAnchoringCore`), reached through these `.so` entry points. `resolvedAnchorBytes` /
 * `refPointBytes` are ssm `SheetMusicJNI.nativeResolveAnchor` / `nativeAnchorReferencePoint` outputs, passed straight
 * through with no decode on this side. Outputs are wirelet `@WireFormat` bytes the caller decodes with the
 * Folino-generated Kotlin codecs (wired in a later sub-plan when persistence / rendering first consume them).
 *
 * All calls return an empty `ByteArray` to signal a miss (undecodable input, an unresolved anchor, or a dropped
 * stroke), matching the Swift side.
 */
object ReaderAnnotationJNI {
    /** bbox-center document-mm point a wet stroke anchors to; send it to `SheetMusicJNI.nativeResolveAnchor`. */
    fun representativePoint(strokeBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeAnnotationRepresentativePoint(
            SwiftData.fromByteArray(strokeBytes, arena),
            arena,
        ).toByteArray()
    }

    /** Capture one wet stroke into a persistable `DrawingAnchorWire`. Empty result = miss (skip the stroke). */
    fun capture(strokeBytes: ByteArray, resolvedAnchorBytes: ByteArray, refPointBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeAnnotationCapture(
            SwiftData.fromByteArray(strokeBytes, arena),
            SwiftData.fromByteArray(resolvedAnchorBytes, arena),
            SwiftData.fromByteArray(refPointBytes, arena),
            arena,
        ).toByteArray()
    }

    /** Batched: one call computes the display transform (`[StrokeTransformWire]`) for a whole annotation layer. */
    fun displayTransforms(drawingsBytes: ByteArray, refPointsBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeAnnotationDisplayTransforms(
            SwiftData.fromByteArray(drawingsBytes, arena),
            SwiftData.fromByteArray(refPointsBytes, arena),
            arena,
        ).toByteArray()
    }
}
