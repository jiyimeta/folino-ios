package com.keynumber.folino.reader.ink

import androidx.ink.brush.Brush
import androidx.ink.brush.InputToolType
import androidx.ink.strokes.MutableStrokeInputBatch
import androidx.ink.strokes.Stroke
import androidx.ink.strokes.StrokeInput
import com.keynumber.folino.reader.RawInkStrokeWire
import com.keynumber.folino.reader.RawInkStrokeWireCodec

/** Bridges androidx.ink `Stroke` geometry to the neutral `RawInkStrokeWire` the Swift FINK codec consumes. */
object InkStrokeSerialization {

    /** Read a finished stroke's inputs (document-mm world coords) into RawInkStrokeWire bytes. */
    fun toRawWireBytes(stroke: Stroke, tool: Int, colorRGBA: Long, baseWidthSp: Float): ByteArray {
        val batch = stroke.inputs
        val n = batch.size
        val scratch = StrokeInput()
        val x = DoubleArray(n); val y = DoubleArray(n); val width = DoubleArray(n)
        val force = DoubleArray(n); val time = IntArray(n)
        for (i in 0 until n) {
            batch.populate(i, scratch)
            x[i] = scratch.x.toDouble(); y[i] = scratch.y.toDouble()
            width[i] = 0.0 // per-point width derived from brush.size + pressure at render; keep 0 in v1
            force[i] = if (scratch.hasPressure) scratch.pressure.toDouble() else 0.0
            time[i] = scratch.elapsedTimeMillis.toInt()
        }
        val wire = RawInkStrokeWire(
            tool = tool.toUByte(),
            colorRGBA = colorRGBA.toUInt(),
            baseWidthSp = baseWidthSp.toDouble(),
            opacity = 1.0,
            x = x.toList(), y = y.toList(), width = width.toList(),
            force = force.toList(), timeMillis = time.toList(),
        )
        return RawInkStrokeWireCodec.encode(wire)
    }

    /** Rebuild an androidx.ink Stroke from RawInkStrokeWire bytes; caller supplies the brush (family+color+size). */
    fun toStroke(rawWireBytes: ByteArray, brush: Brush): Stroke {
        val wire = RawInkStrokeWireCodec.decode(rawWireBytes)
        val batch = MutableStrokeInputBatch()
        for (i in wire.x.indices) {
            batch.add(
                type = InputToolType.STYLUS,
                x = wire.x[i].toFloat(),
                y = wire.y[i].toFloat(),
                elapsedTimeMillis = wire.timeMillis.getOrElse(i) { (i * 8) }.toLong(),
                strokeUnitLengthCm = StrokeInput.NO_STROKE_UNIT_LENGTH,
                pressure = wire.force.getOrNull(i)?.takeIf { it > 0.0 }?.toFloat() ?: StrokeInput.NO_PRESSURE,
            )
        }
        return Stroke(brush, batch)
    }
}
