package com.keynumber.folino.reader

import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.BinaryWriter

// Wire glue for `Data`-typed `@WireletProvided` methods.
//
// The generated `AnnotationPersistenceStore` interface (from FolinoReaderJNI's Swift
// `@WireletProvided` protocol, whose `loadBytes`/`saveBytes` use `Data`) references a
// `com.keynumber.folino.reader.Data` friendly type and a `DataCodec`. At the pinned
// swift-wirelet revision the *provided* Kotlin emitter treats `Data` as an ordinary
// `@WireFormat` type (friendly type `Data`, codec `DataCodec`), but the *model/codec*
// emitter special-cases `Data` to `ByteArray` inline and never emits a standalone
// `Data` model or `DataCodec`. These two declarations close that gap so the generated
// bridge compiles; both are pure Android-side JNI wire glue (no iOS logic).
//
// `Data` is `ByteArray` — the friendly type the Room store and callers use.
typealias Data = ByteArray

/// Length-delimited codec matching swift-wirelet's `Data: WireFormat` conformance
/// (`varint length` + raw bytes) so the JNI payload is byte-identical to the Swift proxy's
/// `Data.encodeToData()` / `Data(decoding:)`. The stored/loaded value is the raw payload
/// (no length prefix) — identical to what iOS persists in `annotation_layers.payload`.
object DataCodec {
    fun encode(value: Data): ByteArray {
        val w = BinaryWriter()
        w.writeLengthPrefixed { writeBytes(value) }
        return w.toByteArray()
    }

    fun decode(bytes: ByteArray): Data {
        val r = BinaryReader(bytes)
        return r.readLengthPrefixed { it.readBytes(it.remaining) }
    }
}
