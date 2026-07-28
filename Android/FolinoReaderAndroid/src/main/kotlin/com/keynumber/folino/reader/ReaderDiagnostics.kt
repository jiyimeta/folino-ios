package com.keynumber.folino.reader

import android.util.Log

/**
 * Non-fatal reporting seam for this module.
 *
 * The Crashlytics wrapper the app records non-fatals through (`com.keynumber.folino.diagnostics.CrashReporting`)
 * lives in the `:app` module, which depends on THIS module — so a Reader-internal call site cannot reach it directly
 * without inverting that edge. The composition root installs [install] once at launch, exactly as it wires every
 * other Infrastructure-shaped concern into a feature; until it does (unit tests, a preview, an instrumented harness)
 * reports fall back to a plain log so nothing is silently swallowed and nothing crashes.
 *
 * Deliberately NOT an `Exception` factory or a message API: the sink takes a [Throwable] so the stack trace is
 * captured at the call site, matching how `CrashReporting.recordNonFatal` is used everywhere else in the app.
 */
object ReaderDiagnostics {
    private const val TAG = "FolinoReader"

    // Written once from the main thread at launch, read from wherever a non-fatal happens (including background
    // dispatchers) — @Volatile is the whole synchronization this needs.
    @Volatile
    private var sink: ((Throwable) -> Unit)? = null

    /** Route this module's non-fatals into the app's crash reporter. Called once, from the composition root. */
    fun install(sink: (Throwable) -> Unit) {
        this.sink = sink
    }

    /**
     * Record a non-fatal. Never throws — a diagnostics failure must not take the reader down with it.
     *
     * The fallback path is `System.err`, not another [Log] call: `android.util.Log` is a stub in a plain JVM unit
     * test and throws `RuntimeException("Method w in android.util.Log not mocked")`, so a `Log`-based fallback would
     * break exactly the promise this doc makes — including for the no-sink branch, which is the one unit tests
     * always take.
     */
    fun recordNonFatal(throwable: Throwable) {
        val installed = sink
        try {
            if (installed != null) {
                installed(throwable)
            } else {
                Log.w(TAG, "non-fatal (no crash-reporting sink installed)", throwable)
            }
        } catch (t: Throwable) {
            System.err.println("[$TAG] non-fatal reporting failed (${t}); original: $throwable")
        }
    }
}
