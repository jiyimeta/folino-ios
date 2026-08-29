package com.keynumber.folino.editor

import androidx.test.platform.app.InstrumentationRegistry
import com.keynumber.folino.editor.generated.EditorBridgeViewModel
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.RestID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import kotlinx.coroutines.MainScope
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * Spec §9's Android persistence gate: an edit made in a session is on disk once the session ends, a fresh session
 * over the same file starts from it, and a discard takes the file back.
 *
 * On device rather than on the JVM because the writer is Swift: `FolinoEditorJNI` is a cross-compiled `.dynamic`
 * product with no host test target, so this is the only automated place the encode and the write are exercised at
 * all.
 *
 * It asserts on FILE BYTES and on a REOPENED session's fingerprint, never on the projection. The projection would go
 * on saying whatever the in-memory core believes even if the write silently did nothing, which is the exact failure
 * this test exists to catch.
 *
 * Unlike [EditSessionParityTest], this suite uses the real [DebouncedAutosave] — the save path IS the subject — and
 * drives it through [EditSessionRelay.flushPendingSave] / `close()` rather than waiting out the 2 s quiet period.
 *
 * Everything that touches the relay runs on the main thread, for the reason [EditSessionParityTest] spells out at
 * length: the relay's contract is one thread, and the generated view model posts its projection updates to
 * `Dispatchers.Main`, so driving it from the instrumentation thread races those posts.
 */
class EditPersistenceTest {

    /** Records what a save asked the library row to become, so the Room-facing half is assertable without Room. */
    private class RecordingRows : ScoreRowRefreshing {
        val calls = mutableListOf<Triple<String, String, String>>()
        override fun refreshAfterSave(id: String, localFileName: String, contentHash: String) {
            calls += Triple(id, localFileName, contentHash)
        }
    }

    /** The host contract's ownership half, as [EditSessionParityTest.TestHost] states it: the relay frees nothing. */
    private class TestHost(var handle: Long) : EditSessionHost {
        val retired = mutableListOf<Long>()
        override fun scoreHandle() = handle
        override fun replaceScoreHandle(handle: Long) {
            if (this.handle != 0L && this.handle != handle) retired += this.handle
            this.handle = handle
        }
        override fun requestRelayout() {}
    }

    private class Rig(
        val bridge: GeneratedEditBridging,
        val host: TestHost,
        val relay: EditSessionRelay,
        val rows: RecordingRows,
        val file: File,
        val scoresDir: File,
        val scoreId: String,
    )

    private val relaysToClose = mutableListOf<EditSessionRelay>()
    private val hostsToRelease = mutableListOf<TestHost>()

    /**
     * Every flush this test performed, in microseconds, logged in [tearDown] under the `EditPersistence` tag.
     *
     * The design takes the MSCZ encode on the main thread deliberately — `EditorBridge` is single-threaded by
     * construction, so moving just the save off it would be a data race rather than an optimization — and a choice
     * like that is worth a number rather than an argument. Measured 2026-08-29 against `parity.mscz`, which is a
     * SMALL fixture (28.8 KB encoded):
     *
     * | | real save | clean flush |
     * | --- | --- | --- |
     * | Pixel 8a | **160-230 ms** | ~2 ms |
     * | `Pixel_6_Pro_API_36` arm64 emulator | 21-24 ms | ~0.2 ms |
     *
     * **The emulator is ~10x optimistic; do not judge this on one.** On the real device a save is over ten dropped
     * frames — well past the 120 ms the SP5 plan set as the line for taking the encode on the main thread.
     *
     * [whereTheFlushTimeGoes] splits what it can. Against the same fixture on a Pixel 8a: encode 88 ms cold and
     * 59 ms warm, the file write 0.7 ms (timed in Kotlin over the same bytes), the digest 1.6 ms, and a clean flush
     * — which still runs `sync()` — 1.4 ms. That accounts for roughly 60 ms of a 212 ms flush.
     *
     * **The remaining ~150 ms was not attributed, and two hypotheses are already dead:** the encoder options are the
     * same on both paths (`MSCXEncoderOptions`' default IS `.v4`), and raising the save `Task` to `.userInitiated`
     * measured as noise, so the cooperative pool's thread priority is not it. What is left is the pool hop itself
     * plus the three JNI upcalls `performSave` makes from a non-JVM thread (`sha256Hex`, `fileSize`, `refreshRow`).
     * A probe op to measure those did not bind (jextract exported it under the `EditorBridge` class while the
     * wirelet view model expected its own `native` symbol), and it was abandoned rather than chased: the attribution
     * does not change the fix. Taking the save off the main thread removes the pool hop, the semaphore and the
     * blocking all at once, whichever of them dominates.
     *
     * Not asserted on: a threshold here would be a flake. Read it from logcat.
     */
    private val flushMicros = mutableListOf<Long>()

    /**
     * Runs [body] on the app's main thread and rethrows anything it threw on this one — without the rethrow an
     * assertion failure inside the block takes the whole app process down and surfaces as "instrumentation run
     * failed" rather than as the assertion.
     */
    private fun onMain(body: () -> Unit) {
        var failure: Throwable? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            try {
                body()
            } catch (throwable: Throwable) {
                failure = throwable
            }
        }
        failure?.let { throw it }
    }

    @After
    fun tearDown() {
        // Before the logging, because `close()` flushes too and those are the most representative saves here.
        onMain { relaysToClose.forEach { it.close() } }
        relaysToClose.clear()
        hostsToRelease.distinctBy { System.identityHashCode(it) }.forEach { host ->
            host.retired.forEach { SheetMusicJNI.nativeReleaseScore(it) }
            host.retired.clear()
            if (host.handle != 0L) SheetMusicJNI.nativeReleaseScore(host.handle)
        }
        hostsToRelease.clear()
        if (flushMicros.isNotEmpty()) {
            val sorted = flushMicros.sorted()
            android.util.Log.i(
                "EditPersistence",
                "flushSave: n=${sorted.size} median=${sorted[sorted.size / 2]}us max=${sorted.last()}us",
            )
        }
    }

    private fun stagedFixture(name: String): Pair<File, File> {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val scoresDir = File(context.filesDir, "Scores").apply { mkdirs() }
        val file = File(scoresDir, "$name.mscz")
        context.assets.open("parity.mscz").use { input -> file.outputStream().use { input.copyTo(it) } }
        return file to scoresDir
    }

    /**
     * Opens a session over [name]'s staged fixture, or over [reopening] when reopening the file a previous session
     * wrote. A reopen loads a FRESH handle off the file, so nothing but the file itself can carry an edit across —
     * and it keeps that session's id, which is what a real reopen of the same library row does.
     *
     * **[scoreId] has to be a UUID string.** `EditorBridge.stubRowPendingSave` parses it with
     * `UUID(uuidString:) ?? UUID()`, so anything else silently becomes a fresh random id and the row refresh then
     * names a row that does not exist. Every real caller passes a library row id, which is
     * `UUID().uuidString` — see `LibraryAndroidStore`'s import path.
     */
    private fun openRig(
        name: String,
        scoreId: String = UUID.randomUUID().toString().uppercase(),
        reopening: Rig? = null,
    ): Rig {
        val (file, scoresDir) = reopening?.let { it.file to it.scoresDir } ?: stagedFixture(name)
        val id = reopening?.scoreId ?: scoreId
        val handle = SheetMusicJNI.nativeLoadScore(file.readBytes())
        assertNotEquals(0L, handle)
        val host = TestHost(handle)
        val rows = RecordingRows()
        lateinit var bridge: GeneratedEditBridging
        lateinit var relay: EditSessionRelay
        var opened: OpenResult? = null
        onMain {
            bridge = GeneratedEditBridging(EditorBridgeViewModel.create(EditorRoomFiles(rows)))
            relay = EditSessionRelay(
                bridge,
                host,
                RealEditNatives,
                // `MainScope()` only has to exist: every save in this suite is a `flushNow` through
                // `flushPendingSave` / `close`, so the quiet period never elapses.
                //
                // Timed here rather than inside `EditorBridge` because this is the boundary that matters and the
                // only one that can report: the whole JNI round trip including the MSCZ encode, taken on the main
                // thread, which is what a user would feel. (Swift's `print` inside the `.so` goes to a stdout
                // Android discards, so a measurement there cannot be read back.)
                autosave = DebouncedAutosave(MainScope()) {
                    val started = System.nanoTime()
                    bridge.flushSave()
                    flushMicros.add((System.nanoTime() - started) / 1_000)
                },
            )
            relaysToClose.add(relay)
            hostsToRelease.add(host)
            opened = relay.open(file.path, scoresDir.path, id)
        }
        assertEquals(OpenResult.OPENED, opened)
        return Rig(bridge, host, relay, rows, file, scoresDir, id)
    }

    /** Writes one quarter-note C into the first bar — the smallest edit that moves the score. */
    private fun writeANote(rig: Rig) = onMain {
        rig.relay.selectItem(ScoreItemIDCodec.encode(ScoreItemID.Rest(firstRestID())))
        rig.relay.armDuration(QUARTER)
        rig.relay.inputPitch("C")
    }

    private fun localFingerprint(rig: Rig): Long {
        var value = 0L
        onMain { value = rig.bridge.scoreFingerprint() }
        return value
    }

    /**
     * Splits the flush cost into its two halves, so "the save is slow" can be acted on rather than only noticed.
     *
     * `encodeScore()` is the same MSCZ encode `performSave` performs (it is the resync path's, over the same score),
     * so timing it alone separates CPU-bound encoding from everything else the save does — the file write, and the
     * `sha256Hex` that reads the file straight back over the JNI seam to digest it.
     */
    @Test fun whereTheFlushTimeGoes() {
        val rig = openRig("persist-cost")
        writeANote(rig)

        // Twice: the first encode in a process pays for warming whatever the encoder touches, and if that is most of
        // the cost then the encode inside the flush — which is never the first — is cheaper than a single probe says.
        var encodeMicros = 0L
        var encodeAgainMicros = 0L
        var encodedBytes = 0
        lateinit var encoded: ByteArray
        onMain {
            var started = System.nanoTime()
            encoded = rig.bridge.encodeScore()
            encodeMicros = (System.nanoTime() - started) / 1_000
            encodedBytes = encoded.size

            started = System.nanoTime()
            rig.bridge.encodeScore()
            encodeAgainMicros = (System.nanoTime() - started) / 1_000
        }

        // The same number of bytes, written to the same directory, by Kotlin. `AndroidScoreWriter` goes through
        // Foundation's `Data.write(to:options:.atomicIfAvailable)`, which writes a temp file and renames; if that is
        // where the unexplained time sits, this comparison is what shows it.
        var kotlinWriteMicros = 0L
        onMain {
            val scratch = File(rig.scoresDir, "cost-probe.bin")
            val started = System.nanoTime()
            scratch.writeBytes(encoded)
            kotlinWriteMicros = (System.nanoTime() - started) / 1_000
            scratch.delete()
        }

        var digestMicros = 0L
        onMain {
            val started = System.nanoTime()
            EditorRoomFiles(rig.rows).sha256Hex(rig.file.path)
            digestMicros = (System.nanoTime() - started) / 1_000
        }

        onMain { rig.relay.flushPendingSave() }

        android.util.Log.i(
            "EditPersistence",
            "cost split: encode=${encodeMicros}us encodeAgain=${encodeAgainMicros}us (${encodedBytes}B) " +
                "digest=${digestMicros}us kotlinWrite=${kotlinWriteMicros}us " +
                "wholeFlush=${flushMicros.last()}us",
        )
    }

    @Test fun anEditReachesTheFileWhenTheSessionEnds() {
        val rig = openRig("persist-basic")
        val before = rig.file.readBytes()

        writeANote(rig)
        onMain { rig.relay.close() }

        assertNotEquals("the edit never reached the file", before.toList(), rig.file.readBytes().toList())
        // And the library row was told where the bytes are now, with a digest in the importer's format.
        val (id, localFileName, contentHash) = rig.rows.calls.last()
        // The id has to come back exactly as the session was opened with — it is the `WHERE id =` of the row
        // refresh, and an id that changed shape on the way through updates nothing, silently.
        assertEquals(rig.scoreId, id)
        assertEquals(rig.file.name, localFileName)
        assertTrue("digest must be lowercase hex SHA-256: $contentHash", contentHash.matches(Regex("[0-9a-f]{64}")))
    }

    @Test fun aReopenedSessionStartsFromTheSavedScore() {
        val rig = openRig("persist-reopen")
        writeANote(rig)
        val edited = localFingerprint(rig)
        onMain { rig.relay.close() }

        val reopened = openRig("persist-reopen", reopening = rig)

        assertEquals("the file does not hold the score the session ended on", edited, localFingerprint(reopened))
        // The other half of the same statement: with the file current, `open()`'s fingerprint check finds the two
        // copies already in agreement. Before SP5 this is exactly where the resync fired, every single time.
        assertEquals("a saved reopen must need no resync", 0, reopened.relay.resyncCount)
    }

    @Test fun aDiscardPutsTheOpeningScoreBackOnDisk() {
        val rig = openRig("persist-discard")
        val opening = localFingerprint(rig)

        writeANote(rig)
        onMain { rig.relay.flushPendingSave() }
        assertTrue("the edit must be on disk before the discard, or this proves nothing", rig.rows.calls.isNotEmpty())
        assertNotEquals("the edit must have moved the score", opening, localFingerprint(rig))

        onMain {
            rig.relay.discardSessionEdits()
            rig.relay.close()
        }

        val reopened = openRig("persist-discard", reopening = rig)
        assertEquals(
            "a discard has to take the FILE back to where the session opened, not only the memory",
            opening,
            localFingerprint(reopened),
        )
    }

    @Test fun undoAndRedoRoundTripThroughTheFile() {
        val rig = openRig("persist-undo")
        writeANote(rig)
        onMain {
            rig.relay.inputPitch("D")
            rig.relay.undo()
            rig.relay.undo()
            rig.relay.redo()
        }
        val expected = localFingerprint(rig)
        onMain { rig.relay.close() }

        val reopened = openRig("persist-undo", reopening = rig)

        assertEquals("the file must hold exactly the score the session ended on", expected, localFingerprint(reopened))
    }

    private companion object {
        const val QUARTER = 3

        /** `parity.mscz`'s first timed slot — see [EditSessionParityTest.firstRestID] for why index 3. */
        fun firstRestID() = RestID(
            staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
            measureIndex = 0,
            voiceIndex = 0,
            elementIndex = 3,
        )
    }
}
