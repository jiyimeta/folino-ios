package com.keynumber.folino.reader

import java.nio.ByteBuffer

/**
 * Decodes the `nativePageBreaks` wire format: big-endian `i32 count` followed by
 * `count × f64` (document-Y page break offsets, mm). `ByteBuffer` defaults to
 * big-endian, matching the Swift `PageBreaksWire` encoder.
 */
object PageBreaksCodec {
    fun decode(bytes: ByteArray): DoubleArray {
        if (bytes.size < 4) return DoubleArray(0)
        val buf = ByteBuffer.wrap(bytes)
        val count = buf.int
        if (count < 0 || bytes.size < 4 + count * 8) return DoubleArray(0)
        return DoubleArray(count) { buf.double }
    }
}
