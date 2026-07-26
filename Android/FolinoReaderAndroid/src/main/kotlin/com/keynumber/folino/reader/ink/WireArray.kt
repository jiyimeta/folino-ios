package com.keynumber.folino.reader.ink

import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.BinaryWriter

/**
 * Wirelet `Array: WireFormat` framing — the framing Swift's top-level `[T].encodeToData()` /
 * `[T](decoding:)` uses (see swift-wirelet `Conformances.swift`, "Array — wire type 2"):
 *
 *   varint(outer byte length) + [ per element: varint(element length) + element payload ]
 *
 * This is the framing the ssm anchor JNI (`SheetMusicJNI.nativeAnchorReferencePoint`, which decodes
 * `[AnchorIdentityWire](decoding:)`) and Folino's `nativeAnnotationDisplayTransforms` (which decodes
 * `[DrawingAnchorWire](decoding:)` / `[AnchorRefPointWire](decoding:)` and returns
 * `[StrokeTransformWire].encodeToData()`) expect.
 *
 * It is DIFFERENT from `io.github.jiyimeta.wirelet.observable.WireletList`, which frames an observable
 * StateFlow list as `varint(element COUNT) + [ length-delimited elements ]`. `WireletList` is correct
 * for the `@WireletObservable` bridge (`AnnotationSaveBridgeViewModel.loadedDrawings`/`drawingsChanged`),
 * but sending its bytes to the array-`decoding:` JNI above silently mis-frames (the leading varint is
 * read as a byte length, not a count) and the Swift decode throws → the JNI returns empty. Use these
 * helpers, not `WireletList`, for the anchor/display-transform JNI calls.
 */
internal fun <T> encodeWireArray(list: List<T>, encodePayload: (T, BinaryWriter) -> Unit): ByteArray {
    val w = BinaryWriter()
    w.writeLengthPrefixed {
        for (element in list) this.writeLengthPrefixed { encodePayload(element, this) }
    }
    return w.toByteArray()
}

internal fun <T> decodeWireArray(bytes: ByteArray, decodePayload: (BinaryReader) -> T): List<T> {
    val r = BinaryReader(bytes)
    return r.readLengthPrefixed { inner ->
        val out = ArrayList<T>()
        while (inner.remaining > 0) out.add(inner.readLengthPrefixed { element -> decodePayload(element) })
        out
    }
}
