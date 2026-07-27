package com.keynumber.folino.reader.ink

import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.AnchorRefPointWireCodec
import com.keynumber.folino.reader.DrawingAnchorWire
import com.keynumber.folino.reader.DrawingAnchorWireCodec
import com.keynumber.folino.reader.PointMmWireCodec
import com.keynumber.folino.reader.ReaderAnnotationJNI
import com.keynumber.folino.reader.ResolvedAnchorWireCodec
import io.github.jiyimeta.sheetmusic.SheetMusicJNI

/**
 * Turns a finished androidx.ink [Stroke] (document-mm world coords) into an anchored, persistable
 * [DrawingAnchorWire]. All math is in shared Swift (reached via [ReaderAnnotationJNI] + ssm's
 * `SheetMusicJNI`) — this only sequences the calls. Returns null when the stroke doesn't anchor
 * (off-staff / unresolved layout).
 */
object AnnotationCaptureController {
    fun capture(
        stroke: Stroke,
        tool: Int,
        colorRGBA: Long,
        baseWidthSp: Float,
        scoreHandle: Long,
    ): DrawingAnchorWire? {
        val rawBytes = InkStrokeSerialization.toRawWireBytes(stroke, tool, colorRGBA, baseWidthSp)
        val fink = ReaderAnnotationJNI.encodeInkStroke(rawBytes)
        if (fink.isEmpty()) return null

        val pointBytes = ReaderAnnotationJNI.representativePoint(fink)
        if (pointBytes.isEmpty()) return null
        val point = PointMmWireCodec.decode(pointBytes)

        val resolvedBytes = SheetMusicJNI.nativeResolveAnchor(scoreHandle, point.xMm, point.yMm)
        if (resolvedBytes.isEmpty()) return null // off-staff / bad coords
        val resolved = ResolvedAnchorWireCodec.decode(resolvedBytes)

        // ssm's `nativeAnchorReferencePoint` wants `[AnchorIdentityWire]` bytes — the identity subset
        // (measureIndex/tickInMeasure/partIndex/staffIndexInPart, wire tags 1-4) of `ResolvedAnchorWire`.
        // The published ssm Android aar does not ship a Kotlin `AnchorIdentityWire` wirelet codec — its
        // `io.github.jiyimeta.sheetmusic` package has no `AnchorIdentityWire`/`AnchorRefPointWire`/
        // `ResolvedAnchorWire` types at all; the only Kotlin surface for those names is the unrelated
        // jextract-swift object binding under `io.github.jiyimeta.sheetmusic.swiftjava` (a different
        // bridging mechanism, not a wirelet `@WireFormat` codec). So `resolved` is re-encoded with
        // Folino's own generated `ResolvedAnchorWireCodec`: its leading four wire tags are identical to
        // `AnchorIdentityWire`'s four Int32 fields, and the trailing dxSp/verticalOffsetSp tags (5-6) land
        // on tags the Swift-side `AnchorIdentityWire` decoder doesn't declare, so it skips them as unknown
        // fields — the same forward-compatible skip every generated codec's decode loop already relies on.
        // List framing MUST be the Wirelet `Array: WireFormat` framing (varint byte-length + per-element
        // length-delimited payloads) that Swift's `[AnchorIdentityWire](decoding:)` expects — see
        // `encodeWireArray`/`decodeWireArray` (WireArray.kt). This is NOT the observable `WireletList`
        // framing (varint COUNT + elements); using WireletList here mis-frames and the Swift decode
        // throws, so `nativeAnchorReferencePoint` returns empty (bug: strokes silently never anchor).
        val refListBytes = SheetMusicJNI.nativeAnchorReferencePoint(
            scoreHandle,
            encodeWireArray(listOf(resolved), ResolvedAnchorWireCodec::encodePayload),
        )
        if (refListBytes.isEmpty()) return null
        val refs = decodeWireArray(refListBytes, AnchorRefPointWireCodec::decodePayload)
        val ref = refs.firstOrNull() ?: return null
        if (ref.spMm == 0.0) return null // unresolved this layout

        val drawingBytes = ReaderAnnotationJNI.capture(fink, resolvedBytes, AnchorRefPointWireCodec.encode(ref))
        if (drawingBytes.isEmpty()) return null
        return DrawingAnchorWireCodec.decode(drawingBytes)
    }
}
