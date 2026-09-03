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

    /** Cut the layer along an eraser path. Empty result = the call failed; leave the layer alone. */
    fun erase(drawingsBytes: ByteArray, transformsBytes: ByteArray, requestBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeAnnotationErase(
            SwiftData.fromByteArray(drawingsBytes, arena),
            SwiftData.fromByteArray(transformsBytes, arena),
            SwiftData.fromByteArray(requestBytes, arena),
            arena,
        ).toByteArray()
    }

    /** Place an anchor-relative stored stroke into document-mm via its display transform. Empty = miss. */
    fun place(strokeBytes: ByteArray, transformBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeAnnotationPlace(
            SwiftData.fromByteArray(strokeBytes, arena),
            SwiftData.fromByteArray(transformBytes, arena),
            arena,
        ).toByteArray()
    }

    /** Encode a raw androidx.ink stroke (RawInkStrokeWire bytes, document-mm) into neutral InkStroke FINK bytes. */
    fun encodeInkStroke(rawBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeEncodeInkStroke(SwiftData.fromByteArray(rawBytes, arena), arena).toByteArray()
    }

    /** Decode neutral InkStroke FINK bytes back to RawInkStrokeWire bytes for rebuilding an androidx.ink Stroke. */
    fun decodeInkStroke(finkBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeDecodeInkStroke(SwiftData.fromByteArray(finkBytes, arena), arena).toByteArray()
    }

    /**
     * PDF page-anchor sibling of [capture]: capture one wet stroke already known to belong to [pageIndex]
     * (paged mode: the single visible page) into a persistable `.page` `DrawingAnchorWire`. Unlike
     * [capture], there is no ssm round trip — `pageFrameBytes` (that page's current content-space frame,
     * `PageFrameWire`) is display-only input Kotlin's own PDF renderer already has. Empty result = miss
     * (undecodable input, or a non-positive page width — skip the stroke). See [pdfCaptureResolvingPage]
     * for the vertical-surface sibling, which resolves the page itself instead of taking it as an input.
     */
    fun pdfCapture(strokeBytes: ByteArray, pageIndex: Int, pageFrameBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativePdfAnnotationCapture(
            SwiftData.fromByteArray(strokeBytes, arena),
            pageIndex,
            SwiftData.fromByteArray(pageFrameBytes, arena),
            arena,
        ).toByteArray()
    }

    /**
     * PDF page-anchor sibling of [pdfCapture] for the vertical surface: capture one wet stroke, resolving
     * which page it belongs to from its own representative point (bbox center) against `pageFramesBytes`
     * (a `PageFramesWire`, the whole document's current page layout — the SAME one `pdfDisplayTransforms`
     * takes). The centroid → page decision (including its inter-page-gap fallback) happens entirely in
     * shared Swift (`PageAnchoringCore.pageIndex(forCentroid:pageFrames:)`), so Kotlin carries none of that
     * geometry itself. Empty result = miss (undecodable input, or the centroid doesn't resolve to any page
     * — an empty `pageFramesBytes`).
     */
    fun pdfCaptureResolvingPage(strokeBytes: ByteArray, pageFramesBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativePdfAnnotationCaptureResolvingPage(
            SwiftData.fromByteArray(strokeBytes, arena),
            SwiftData.fromByteArray(pageFramesBytes, arena),
            arena,
        ).toByteArray()
    }

    /**
     * PDF page-anchor sibling of [displayTransforms]: batched display transform for a whole layer against
     * the PDF's current page layout (`pageFramesBytes` = `PageFramesWire`, positionally indexed by page).
     * `sp == 0` in the result marks a drawing that isn't placeable this frame — a `.musical` wire (this
     * path only ever draws page anchors) or a `.page` wire whose page's frame isn't known this frame.
     */
    fun pdfDisplayTransforms(drawingsBytes: ByteArray, pageFramesBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativePdfAnnotationDisplayTransforms(
            SwiftData.fromByteArray(drawingsBytes, arena),
            SwiftData.fromByteArray(pageFramesBytes, arena),
            arena,
        ).toByteArray()
    }

    /**
     * Which control ends an annotation session, for a session that has (or hasn't) changed anything on a score that
     * carries (or doesn't carry) ink. No bytes to marshal — the only reason it crosses at all is that the RULE is
     * shared: `AnnotationSessionEndMode.derive` is the one place either platform decides this, and iOS's own header
     * calls the same function in-process. A three-line Kotlin copy would read as free and then drift.
     */
    fun sessionEndMode(sessionHasChanges: Boolean, hasInk: Boolean): AnnotationSessionEndMode =
        AnnotationSessionEndMode.fromRawValue(
            SwiftJavaJNI.nativeAnnotationSessionEndMode(sessionHasChanges, hasInk),
        )
}
