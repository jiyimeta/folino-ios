package com.keynumber.folino.reader.pdf

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.Size
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import java.io.File
import java.util.concurrent.Executors

/**
 * Pages to keep rasterized around [current], clamped to the document. Empty when there are no
 * pages. Split out from [PdfPageSource] because it is pure arithmetic and the only part of the PDF
 * pipeline that is unit-testable off-device — [PdfPageSource] itself needs a real `PdfRenderer`.
 */
internal object PdfPageWindow {
    fun range(current: Int, pageCount: Int, radius: Int): IntRange {
        if (pageCount <= 0) return IntRange.EMPTY
        val lo = (current - radius).coerceIn(0, pageCount - 1)
        val hi = (current + radius).coerceIn(0, pageCount - 1)
        return lo..hi
    }
}

/**
 * Rasterizes pages of [file] on demand and caches only a window of them, so a 20+ page score
 * doesn't hold every page's bitmap in memory at once (a full-page bitmap at high zoom is many
 * megabytes). Callers drive the window with [setWindow] as the visible page changes; the render
 * surfaces (Tasks 7/8) fetch bitmaps with [bitmap].
 *
 * `PdfRenderer` permits only one open `Page` at a time process-wide for a given renderer instance —
 * concurrent access is a documented crash, not just a performance concern. Every touch of
 * [renderer] or a `Page` it opens therefore happens inside [lock], which also guards [cache] so a
 * synchronous [pageSizePt] call can never interleave with an in-flight [bitmap] render. Actual
 * rendering additionally runs on [dispatcher], a dedicated single-thread executor, so it never
 * blocks the caller's thread (typically the main thread for Compose call sites); [lock] is what
 * makes the two access paths (the async render path and the synchronous [pageSizePt]/[close] paths)
 * mutually exclusive, since [pageSizePt] can't itself be routed through a suspend hop without
 * risking a nested-`runBlocking` deadlock if ever called from a coroutine already on [dispatcher].
 */
internal class PdfPageSource(file: File) : AutoCloseable {

    private class CachedPage(var bitmap: Bitmap?, var widthPx: Int, var job: Deferred<Bitmap?>?)

    private val dispatcherExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "PdfPageSource") }
    private val dispatcher = dispatcherExecutor.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    // Guards every access to `renderer`/its pages AND every access to `cache`+`closed`, so the two
    // access paths above can never interleave. See the class doc for why a single lock (rather than
    // routing pageSizePt through `dispatcher`) is the right tool here.
    private val lock = Any()

    private val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    private val renderer = PdfRenderer(descriptor)

    val pageCount: Int = renderer.pageCount

    private val cache = HashMap<Int, CachedPage>()
    private var closed = false

    /** [PdfRenderer.Page.getWidth]/[getHeight] for [index], in PDF points (1/72 inch). */
    fun pageSizePt(index: Int): Size = synchronized(lock) {
        renderer.openPage(index).use { page -> Size(page.width, page.height) }
    }

    /**
     * The rasterized bitmap for [index] at [widthPx] wide (height follows the page's aspect ratio),
     * `ARGB_8888`, rendered `RENDER_MODE_FOR_DISPLAY`. Returns the cached bitmap immediately if one
     * already exists for that exact width; otherwise renders on [dispatcher] and caches the result.
     * Returns null if [index] is out of range, the page fails to render, or the source is [close]d
     * (including while the render was in flight — see [setWindow]).
     */
    suspend fun bitmap(index: Int, widthPx: Int): Bitmap? {
        val deferred = ensureRenderJob(index, widthPx)
        return try {
            deferred.await()
        } catch (e: CancellationException) {
            null
        }
    }

    private fun ensureRenderJob(index: Int, widthPx: Int): Deferred<Bitmap?> = synchronized(lock) {
        if (closed) return@synchronized CompletableDeferred(null)

        val cached = cache.getOrPut(index) { CachedPage(bitmap = null, widthPx = -1, job = null) }
        if (cached.bitmap != null && cached.widthPx == widthPx) {
            return@synchronized CompletableDeferred(cached.bitmap)
        }
        val inFlight = cached.job
        if (inFlight != null && inFlight.isActive && cached.widthPx == widthPx) {
            return@synchronized inFlight
        }
        // A different width superseded whatever this page was rendering (or caching) before.
        inFlight?.cancel()
        val job = scope.async { renderAndCache(index, widthPx) }
        cached.job = job
        cached.widthPx = widthPx
        job
    }

    /** Runs on [dispatcher]. Opens, renders, and closes exactly one page — never two at once. */
    private fun renderAndCache(index: Int, widthPx: Int): Bitmap? {
        val rendered = synchronized(lock) {
            if (closed) return@synchronized null
            try {
                renderer.openPage(index).use { page ->
                    val heightPx = (widthPx.toLong() * page.height / page.width).toInt().coerceAtLeast(1)
                    Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888).also { bitmap ->
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    }
                }
            } catch (e: Exception) {
                null
            }
        }
        synchronized(lock) {
            val cached = cache[index]
            // The entry was dropped by setWindow, replaced by a newer width, or the source was
            // closed while this render was in flight: discard the result instead of resurrecting it.
            if (closed || cached == null || cached.widthPx != widthPx) {
                rendered?.recycle()
                return null
            }
            if (cached.bitmap !== rendered) cached.bitmap?.recycle()
            cached.bitmap = rendered
            cached.job = null
        }
        return rendered
    }

    /**
     * Recycles and drops every cached page outside [PdfPageWindow.range] for (current, [radius]),
     * cancelling any in-flight render for a dropped page. This is the memory guard: callers move the
     * window as the visible page changes so at most `2 * radius + 1` bitmaps are ever held.
     */
    fun setWindow(current: Int, radius: Int) {
        val keep = PdfPageWindow.range(current, pageCount, radius)
        synchronized(lock) {
            val iterator = cache.entries.iterator()
            while (iterator.hasNext()) {
                val (index, cached) = iterator.next()
                if (index !in keep) {
                    cached.job?.cancel()
                    cached.bitmap?.recycle()
                    iterator.remove()
                }
            }
        }
    }

    /** Closes the renderer and the descriptor and recycles the cache. Safe to call more than once. */
    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            for (cached in cache.values) {
                cached.job?.cancel()
                cached.bitmap?.recycle()
            }
            cache.clear()
            renderer.close()
            descriptor.close()
        }
        scope.cancel()
        dispatcherExecutor.shutdown()
    }
}
