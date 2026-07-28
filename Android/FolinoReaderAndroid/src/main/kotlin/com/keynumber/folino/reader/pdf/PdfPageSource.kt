package com.keynumber.folino.reader.pdf

import android.graphics.Bitmap
import android.graphics.Color
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
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
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
 * Whether a just-finished render for ([generation], [widthPx]) may still be installed into the cache
 * slot it was launched for, given that slot's CURRENT state ([cachedGeneration], [cachedWidthPx]) and
 * whether the source has since been [closed]. False in every case means: discard the render (and
 * recycle it — it was never handed to any caller) instead of writing it into the cache.
 *
 * This is the exact predicate [PdfPageSource.renderAndCache] guards its cache write with, pulled out
 * as pure `Int`/`Boolean` logic (no `PdfRenderer`, `Bitmap`, or coroutine involved) specifically so the
 * race it closes — a stale render from an evicted-then-recreated slot installing over, or racing to
 * overwrite, a newer render for the same page index — is unit-testable off-device. The one case this
 * function does NOT cover is an evicted slot (removed from the cache entirely, not just recreated):
 * callers are expected to treat `cache[index] == null` as an immediate "don't install" on their own,
 * since there is no cached state left to compare against.
 */
internal object PdfRenderInstall {
    fun canInstall(generation: Int, widthPx: Int, cachedGeneration: Int, cachedWidthPx: Int, closed: Boolean): Boolean {
        if (closed) return false
        if (cachedGeneration != generation) return false
        if (cachedWidthPx != widthPx) return false
        return true
    }
}

/**
 * Rasterizes pages of [file] on demand and caches only a window of them, so a 20+ page score
 * doesn't hold every page's bitmap in memory at once (a full-page bitmap at high zoom is many
 * megabytes). Callers drive the window with [setWindow] as the visible page changes; the render
 * surfaces (Tasks 7/8) fetch bitmaps with [bitmap].
 *
 * **Construction is blocking.** The constructor opens the file, creates the `PdfRenderer`, and walks
 * every page once to precompute [pageSizesPt] (see below) — unbounded work proportional to the page
 * count, run synchronously on whatever thread constructs this. Tasks 7/8 must build a `PdfPageSource`
 * off the main thread (e.g. `Dispatchers.IO`, as `ReaderViewModel.openPdf` already does), never inline
 * in a `@Composable` or a main-thread call site. A throw partway through construction (a corrupt page)
 * closes whatever of the descriptor/renderer was already opened before propagating, so a failed
 * construction never leaks — see the `try`/`catch` around [renderer] and [pageSizesPt] below.
 *
 * `PdfRenderer` permits only one open `Page` at a time process-wide for a given renderer instance —
 * concurrent access is a documented crash, not just a performance concern. Every touch of [renderer]
 * or a `Page` it opens happens inside [rendererLock] — that includes the constructor's page-size
 * sweep, [renderAndCache]'s render call (which runs on [dispatcher], a dedicated single-thread
 * executor, so a render never blocks the caller's thread — typically the main thread for Compose call
 * sites), and [close]'s teardown, which is itself posted to [dispatcher] rather than run inline so that
 * closing from the main thread never waits on an in-flight render.
 *
 * [pageSizePt] does NOT take [rendererLock] on the hot path: every page's size is read once, up front,
 * in the constructor into [pageSizesPt], so normal lookups are a plain array read. That matters because
 * [pageSizePt] is not `suspend`: routing it through [dispatcher] would mean blocking the caller
 * (`runBlocking`), which risks deadlock if ever called from a coroutine already running on [dispatcher],
 * and taking [rendererLock] synchronously would block the caller behind an in-flight render (150-400ms
 * for a large page) — the exact main-thread stall [dispatcher] exists to avoid.
 *
 * A second, short lock, [cacheLock], separately guards [cache] and [closed]: [ensureRenderJob],
 * [renderAndCache]'s cache update, [setWindow], and the bookkeeping half of [close] all take it.
 * Splitting the two locks means [setWindow]/cache lookups never block behind a render in flight.
 *
 * Ownership of returned bitmaps: see [bitmap]'s KDoc.
 */
internal class PdfPageSource(file: File) : AutoCloseable {

    private class CachedPage(var bitmap: Bitmap?, var widthPx: Int, var job: Deferred<Bitmap?>?, val generation: Int)

    private val dispatcherExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "PdfPageSource") }
    private val dispatcher = dispatcherExecutor.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    // Guards every access to `renderer`/its pages (the constructor's page-size sweep, `renderAndCache`'s
    // render call, and `close`'s renderer/descriptor teardown). See the class doc for why `pageSizePt`
    // deliberately does NOT take this lock on its hot path.
    private val rendererLock = Any()

    // Guards `cache`, `closed`, and `nextGeneration` — everything that decides what's cached and
    // what's in flight, independent of the (possibly slow) render work itself.
    private val cacheLock = Any()

    private val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)

    // If `PdfRenderer(descriptor)` throws (e.g. a corrupt file), nobody will ever hold a reference to
    // this half-constructed instance to call `close()` on — the throw propagates straight out of `<init>`
    // to the caller (`ReaderViewModel.openPdf`'s `catch`). Close the descriptor ourselves before
    // rethrowing, or its fd survives to finalization instead of being released promptly.
    private val renderer = try {
        PdfRenderer(descriptor)
    } catch (t: Throwable) {
        descriptor.close()
        throw t
    }

    val pageCount: Int = renderer.pageCount

    // Read once, up front, under `rendererLock` (before the object is published to any other thread,
    // so the lock here is belt-and-suspenders rather than load-bearing) — see the class doc for why.
    // Same leak hazard as `renderer` above: a throw mid-sweep (a corrupt page) must close both the
    // renderer and the descriptor before propagating, since — again — nothing else can reach them yet.
    private val pageSizesPt: Array<Size> = try {
        synchronized(rendererLock) {
            Array(pageCount) { i -> renderer.openPage(i).use { page -> Size(page.width, page.height) } }
        }
    } catch (t: Throwable) {
        renderer.close()
        descriptor.close()
        throw t
    }

    private val cache = HashMap<Int, CachedPage>()

    // Read from `renderAndCache` (on `dispatcher`) without `cacheLock` held, and written only under
    // `cacheLock` in `close`; `@Volatile` gives that read a visibility guarantee without a lock.
    @Volatile
    private var closed = false

    // Bumped every time a cache slot is (re)created for an index that had none — see `ensureRenderJob`
    // and the generation check in `renderAndCache` for why an entry's identity alone isn't enough.
    private var nextGeneration = 0

    /**
     * [PdfRenderer.Page.getWidth]/[getHeight] for [index], in PDF points (1/72 inch). Precomputed at
     * construction (see [pageSizesPt]): a plain array lookup, no lock, never touches [renderer].
     *
     * Unlike [bitmap], which treats an out-of-range index as a soft "nothing to show" (returns null —
     * a render surface's index can legitimately be stale for a tick), an out-of-range index here is a
     * caller bug: every real call site (`ReaderViewModel.openPdf`'s page-size sweep) iterates
     * `0 until pageCount` itself, so there's no legitimate reason to ask for a size outside that range.
     * [require] makes that an explicit, documented contract instead of an incidental
     * `ArrayIndexOutOfBoundsException` from [pageSizesPt].
     */
    fun pageSizePt(index: Int): Size {
        require(index in 0 until pageCount) { "index $index out of range [0, $pageCount)" }
        return pageSizesPt[index]
    }

    /**
     * The rasterized bitmap for [index] at [widthPx] wide (height follows the page's aspect ratio),
     * `ARGB_8888` prefilled white then rendered `RENDER_MODE_FOR_DISPLAY` (a PDF page doesn't paint
     * its own background, so an unfilled bitmap would show transparent — the score reading as ink
     * floating on the reader's background, most visible in dark theme). Returns the cached bitmap
     * immediately if one already exists for that exact width; otherwise renders on [dispatcher] and
     * caches the result. Returns null if [index] is out of range, the source is already [close]d, the
     * page fails to render (including an `OutOfMemoryError` from the allocation), or the render was
     * superseded/dropped before it could be installed (e.g. by [setWindow] evicting [index], or a
     * newer [bitmap] call for a different width).
     *
     * Ownership: a bitmap this returns is NEVER force-recycled afterward. [setWindow] and a
     * superseding render both drop a cached bitmap's reference rather than calling `recycle()` on
     * it, precisely so a caller already drawing a previously returned bitmap (e.g. Tasks 7/8 holding
     * it in a Compose `Painter`) never has it pulled out from under them. Memory is bounded by the
     * window itself (at most `2 * radius + 1` bitmaps ever cached), not by explicit recycling; a
     * dropped bitmap's native memory is reclaimed once nothing — cache or caller — references it.
     */
    suspend fun bitmap(index: Int, widthPx: Int): Bitmap? {
        val deferred = ensureRenderJob(index, widthPx)
        return try {
            deferred.await()
        } catch (e: CancellationException) {
            // Only swallow this when it's specifically THIS render job that was cancelled (e.g. by
            // `setWindow` dropping the page) while the calling coroutine is still active. If the
            // caller's own context is no longer active, this is real structured-concurrency
            // cancellation and must keep propagating.
            if (!currentCoroutineContext().isActive) throw e
            null
        }
    }

    private fun ensureRenderJob(index: Int, widthPx: Int): Deferred<Bitmap?> {
        if (index < 0 || index >= pageCount) return CompletableDeferred(null)
        return synchronized(cacheLock) {
            if (closed) return@synchronized CompletableDeferred(null)

            val cached = cache.getOrPut(index) {
                CachedPage(bitmap = null, widthPx = -1, job = null, generation = nextGeneration++)
            }
            if (cached.bitmap != null && cached.widthPx == widthPx) {
                return@synchronized CompletableDeferred(cached.bitmap)
            }
            val inFlight = cached.job
            if (inFlight != null && inFlight.isActive && cached.widthPx == widthPx) {
                return@synchronized inFlight
            }
            // A different width superseded whatever this page was rendering (or caching) before. The
            // entry (and so its generation) is reused — only its bitmap/width/job are replaced. Clearing
            // `bitmap` HERE, in lockstep with `widthPx`, is what keeps the cache-hit check above honest:
            // without it, a request for the new width could match `widthPx == widthPx` while `bitmap`
            // still held the OLD width's pixels, handing out a wrong-resolution bitmap.
            inFlight?.cancel()
            val job = scope.async { renderAndCache(index, widthPx, cached.generation) }
            cached.job = job
            cached.bitmap = null
            cached.widthPx = widthPx
            job
        }
    }

    /**
     * Runs on [dispatcher]. Opens, renders, and closes exactly one page — never two at once.
     * [generation] pins this render to the specific cache-slot instance [ensureRenderJob] launched it
     * for: if [setWindow] evicted that slot and a later call recreated it (getting a NEW generation)
     * before this render finished, [generation] no longer matches and the result is discarded instead
     * of being installed over — or racing to overwrite — the newer slot's own in-flight render. The
     * eviction case (the slot is gone entirely) and the generation/width-mismatch cases (the slot
     * exists but moved on) are checked separately below; see [PdfRenderInstall.canInstall] for the
     * latter, extracted specifically so that part is unit-testable without a real `PdfRenderer`.
     */
    private fun renderAndCache(index: Int, widthPx: Int, generation: Int): Bitmap? {
        val rendered = try {
            synchronized(rendererLock) {
                if (closed) return@synchronized null
                renderer.openPage(index).use { page ->
                    val heightPx = (widthPx.toLong() * page.height / page.width).toInt().coerceAtLeast(1)
                    try {
                        Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888).also { bitmap ->
                            bitmap.eraseColor(Color.WHITE)
                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        }
                    } catch (oom: OutOfMemoryError) {
                        null
                    }
                }
            }
        } catch (_: Exception) {
            null
        }
        synchronized(cacheLock) {
            val cached = cache[index]
            // `rendered` was never handed to any caller at this point (a discarded render here is
            // recycled, never installed), so recycling it in either branch below is always safe.
            if (cached == null ||
                !PdfRenderInstall.canInstall(generation, widthPx, cached.generation, cached.widthPx, closed)
            ) {
                rendered?.recycle()
                return null
            }
            // Drop (never recycle) whatever bitmap was cached before: a caller may already have
            // received it via the cache-hit fast path in `ensureRenderJob` and could be drawing it
            // right now. See `bitmap`'s KDoc for the ownership contract this relies on.
            cached.bitmap = rendered
            cached.job = null
        }
        return rendered
    }

    /**
     * Drops every cached page outside [PdfPageWindow.range] for (current, [radius]) — never
     * recycling a dropped bitmap, only forgetting it (see [bitmap]'s ownership contract) — and
     * cancels any in-flight render for a dropped page. This is the memory guard: callers move the
     * window as the visible page changes so at most `2 * radius + 1` renders are ever cached.
     */
    fun setWindow(current: Int, radius: Int) {
        val keep = PdfPageWindow.range(current, pageCount, radius)
        synchronized(cacheLock) {
            val iterator = cache.entries.iterator()
            while (iterator.hasNext()) {
                val (index, cached) = iterator.next()
                if (index !in keep) {
                    cached.job?.cancel()
                    iterator.remove()
                }
            }
        }
    }

    /**
     * Closes the renderer and the descriptor and forgets the cache. Safe to call more than once.
     *
     * **Returns without waiting for the native teardown.** The bookkeeping half — flipping [closed] and
     * cancelling in-flight jobs — is synchronous under [cacheLock], which is only ever held for a few
     * `HashMap` operations. The `renderer`/`descriptor` teardown is handed to [dispatcher] instead, because
     * every real caller is on the MAIN thread (`ReaderViewModel`'s retarget cleanup and `onCleared`) and
     * taking [rendererLock] here would block it behind whatever page is mid-rasterization — 150-400ms for a
     * large page, considerably more at high zoom with several windowed pages re-rastering after a pinch.
     *
     * Handing it to [dispatcher] is also what makes the teardown safe without a wait: [dispatcher] is a
     * single thread, so this task is already ordered AFTER any render currently running on it, and
     * [ensureRenderJob] refuses to launch a new one once [closed] is set (which happens above, before this
     * is even submitted). A render that was dispatched but not yet started re-checks [closed] under
     * [rendererLock] before `openPage`, so whichever order the two land in, no render can touch a closed
     * renderer. [rendererLock] is kept around the teardown for that same interlock rather than for mutual
     * exclusion against a render that, by the above, can no longer be in flight.
     *
     * Submitting before `shutdown()` matters: `shutdown()` lets already-queued tasks run, but rejects new
     * ones.
     */
    override fun close() {
        synchronized(cacheLock) {
            if (closed) return
            closed = true
            for (cached in cache.values) {
                cached.job?.cancel()
            }
            cache.clear()
        }
        dispatcherExecutor.execute {
            synchronized(rendererLock) {
                renderer.close()
                descriptor.close()
            }
        }
        scope.cancel()
        dispatcherExecutor.shutdown()
    }
}
