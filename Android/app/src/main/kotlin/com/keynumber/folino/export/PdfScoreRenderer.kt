package com.keynumber.folino.export

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import com.keynumber.folino.library.ScorePdfRenderer
import com.keynumber.folino.reader.LayoutOptions
import io.github.jiyimeta.sheetmusic.BravuraMetricsBuilder
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramReader
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand
import io.github.jiyimeta.sheetmusic.compose.draw.model.EncodablePage
import io.github.jiyimeta.sheetmusic.compose.draw.model.FontID
import java.io.File

// A4 page in millimetres — must match the Reader's single-page layout so the
// PDF reflows identically to what's shown on screen (see ReaderViewModel).
private const val PAGE_WIDTH_MM = 210.0
private const val PAGE_HEIGHT_MM = 297.0

// PDF user space is points (1pt = 1/72"). DrawProgram coordinates are mm.
private const val MM_TO_PT = 72.0 / 25.4

/**
 * Kotlin implementation of the generated `@WireletProvided` [ScorePdfRenderer],
 * injected into the Swift `LibraryAndroidStore` over JNI.
 *
 * Reads the `.mscz` at `scoreFilePath`, computes the shared layout
 * [io.github.jiyimeta.sheetmusic.compose.draw.model.DrawProgram], and paints
 * each page into a [PdfDocument] written to `outPath`. The per-`DrawCommand`
 * draw routine is a faithful port of swift-sheet-music's `ScoreCanvas`
 * (Compose) to a raw [Canvas]; the only difference is the coordinate scale —
 * here mm map to PDF points instead of pixels-per-mm.
 */
class PdfScoreRenderer(context: Context) : ScorePdfRenderer {

    private val appContext = context.applicationContext

    private val bravura: Typeface by lazy {
        Typeface.createFromAsset(appContext.assets, "fonts/Bravura.otf")
    }
    private val edwin: Typeface by lazy {
        Typeface.createFromAsset(appContext.assets, "fonts/Edwin-Roman.otf")
    }

    override fun renderPdf(scoreFilePath: String, outPath: String): Boolean {
        var handle: ScoreHandle? = null
        return try {
            val bytes = File(scoreFilePath).readBytes()

            // SMuFL metrics must be installed before computing layout (mirrors
            // ReaderViewModel). Idempotent — safe to call per export.
            val table = BravuraMetricsBuilder.buildTable(appContext.assets)
            SheetMusicJNI.nativeInstallSMuFLMetrics(table)

            val h = ScoreHandle.load(bytes) ?: return false
            handle = h

            // PDF export uses default display options (vertical, 28pt, no overrides).
            // nativeComputeLayout returns empty Data on an undecodable blob, so pass a
            // real encoded LayoutOptions.DEFAULT rather than an empty array.
            val programBytes = SheetMusicJNI.nativeComputeLayout(
                h.raw, PAGE_WIDTH_MM, PAGE_HEIGHT_MM, LayoutOptions.DEFAULT.encode(),
            )
            if (programBytes.isEmpty()) return false
            val program = DrawProgramReader.decode(programBytes)
            if (program.pages.isEmpty()) return false

            val doc = PdfDocument()
            try {
                program.pages.forEachIndexed { index, page ->
                    val widthPt = (page.widthMM * MM_TO_PT).toInt().coerceAtLeast(1)
                    val heightPt = (page.heightMM * MM_TO_PT).toInt().coerceAtLeast(1)
                    val pageInfo = PdfDocument.PageInfo.Builder(widthPt, heightPt, index + 1).create()
                    val pdfPage = doc.startPage(pageInfo)
                    // Scale mm -> pt so the score fills the page at the right
                    // physical size; the draw routine works in mm.
                    pdfPage.canvas.scale(MM_TO_PT.toFloat(), MM_TO_PT.toFloat())
                    drawPage(pdfPage.canvas, page)
                    doc.finishPage(pdfPage)
                }
                File(outPath).outputStream().use { doc.writeTo(it) }
            } finally {
                doc.close()
            }
            true
        } catch (e: Exception) {
            android.util.Log.w("PdfScoreRenderer", "pdf export failed for $scoreFilePath", e)
            false
        } finally {
            handle?.close()
        }
    }

    /**
     * Port of `ScoreCanvas.drawPage`. Coordinates are millimetres; the caller
     * has already scaled the canvas mm -> pt, so commands draw in mm directly.
     */
    private fun drawPage(canvas: Canvas, page: EncodablePage) {
        val path = Path()
        var strokeStarted = false
        var currentArgb: Int = Color.BLACK
        val glyphPaint = Paint().apply {
            isAntiAlias = true
            color = currentArgb
        }
        val strokePaint = Paint().apply {
            isAntiAlias = true
            style = Paint.Style.STROKE
        }
        val fillPaint = Paint().apply {
            isAntiAlias = true
            style = Paint.Style.FILL
        }
        for (cmd in page.commands) {
            when (cmd) {
                is DrawCommand.MoveTo -> {
                    if (strokeStarted) path.reset()
                    path.moveTo(cmd.x.toFloat(), cmd.y.toFloat())
                    strokeStarted = true
                }
                is DrawCommand.LineTo -> {
                    path.lineTo(cmd.x.toFloat(), cmd.y.toFloat())
                }
                is DrawCommand.CubicTo -> {
                    path.cubicTo(
                        cmd.cx1.toFloat(), cmd.cy1.toFloat(),
                        cmd.cx2.toFloat(), cmd.cy2.toFloat(),
                        cmd.x.toFloat(), cmd.y.toFloat(),
                    )
                }
                is DrawCommand.Stroke -> {
                    // Stroke widths are in mm (post-scale = pt). The Compose
                    // renderer coerced to a px floor for screen legibility; in a
                    // vector PDF we keep the true width so it stays resolution-
                    // independent.
                    strokePaint.color = currentArgb
                    strokePaint.strokeWidth = cmd.width.toFloat()
                    canvas.drawPath(path, strokePaint)
                    path.reset()
                    strokeStarted = false
                }
                is DrawCommand.FillRect -> {
                    fillPaint.color = currentArgb
                    canvas.drawRect(
                        cmd.x.toFloat(),
                        cmd.y.toFloat(),
                        (cmd.x + cmd.w).toFloat(),
                        (cmd.y + cmd.h).toFloat(),
                        fillPaint,
                    )
                }
                is DrawCommand.Glyph -> {
                    glyphPaint.typeface = if (cmd.fontId == FontID.SMUFL) bravura else edwin
                    glyphPaint.textSize = cmd.size.toFloat()
                    glyphPaint.color = currentArgb
                    val s = String(intArrayOf(cmd.codepoint.toInt()), 0, 1)
                    canvas.drawText(s, cmd.x.toFloat(), cmd.y.toFloat(), glyphPaint)
                }
                is DrawCommand.Text -> {
                    glyphPaint.typeface = if (cmd.fontId == FontID.SMUFL) bravura else edwin
                    glyphPaint.textSize = cmd.size.toFloat()
                    glyphPaint.color = currentArgb
                    canvas.drawText(cmd.text, cmd.x.toFloat(), cmd.y.toFloat(), glyphPaint)
                }
                is DrawCommand.SetColor -> {
                    currentArgb = cmd.argb.toInt()
                }
            }
        }
    }
}
