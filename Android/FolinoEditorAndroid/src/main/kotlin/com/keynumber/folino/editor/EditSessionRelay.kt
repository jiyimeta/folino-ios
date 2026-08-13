package com.keynumber.folino.editor

import android.util.Log
import com.keynumber.folino.editor.generated.EditorBridgeViewModel
import io.github.jiyimeta.sheetmusic.SheetMusicJNI

/**
 * The ssm entry points the relay uses, behind an interface so the JVM tests can drive the policy without a device.
 * The real implementation is a straight delegation — nothing may be added to it, or the tests stop covering what
 * ships.
 */
interface EditNatives {
    fun engineVersionStamp(): Long
    fun beginEditSession(handle: Long): Boolean
    fun applyEditIntent(handle: Long, bytes: ByteArray): Boolean
    fun editUndo(handle: Long): Boolean
    fun editRedo(handle: Long): Boolean
    fun endEditSession(handle: Long)
    fun scoreFingerprint(handle: Long): Long
    fun loadScore(bytes: ByteArray): Long
    fun releaseScore(handle: Long)
}

object RealEditNatives : EditNatives {
    override fun engineVersionStamp() = SheetMusicJNI.nativeEngineVersionStamp()
    override fun beginEditSession(handle: Long) = SheetMusicJNI.nativeBeginEditSession(handle)
    override fun applyEditIntent(handle: Long, bytes: ByteArray) = SheetMusicJNI.nativeApplyEditIntent(handle, bytes)
    override fun editUndo(handle: Long) = SheetMusicJNI.nativeEditUndo(handle)
    override fun editRedo(handle: Long) = SheetMusicJNI.nativeEditRedo(handle)
    override fun endEditSession(handle: Long) = SheetMusicJNI.nativeEndEditSession(handle)
    override fun scoreFingerprint(handle: Long) = SheetMusicJNI.nativeScoreFingerprint(handle)
    override fun loadScore(bytes: ByteArray) = SheetMusicJNI.nativeLoadScore(bytes)
    override fun releaseScore(handle: Long) = SheetMusicJNI.nativeReleaseScore(handle)
}

/**
 * The bridge surface the relay drives, behind an interface for the same reason `EditNatives` is one: the generated
 * `EditorBridgeViewModel` is a final class over JNI, so the relay's policy — the part actually worth being sure
 * about — would otherwise be testable only on a device. `GeneratedEditBridging` must stay a pure delegation.
 *
 * Ops are declared here as the relay needs them; add one per op the relay exposes.
 */
interface EditBridging {
    fun engineVersionStamp(): Long
    fun beginSession(path: String, dir: String, id: String): Boolean
    fun endSession()
    fun scoreFingerprint(): Long
    fun encodeScore(): ByteArray
    fun takeRelayFrames(): List<ByteArray>
    fun revision(): Int
    fun appliedIntentCount(): Int

    fun selectItem(bytes: ByteArray)
    fun inputPitch(letter: String)
    fun deleteSelection()
    fun writeRest()
    fun armDuration(kind: Int)
    fun toggleArmedDot()
    fun setArmedDots(dots: Int)
    fun setSelectionDuration(kind: Int)
    fun setSelectionDots(dots: Int)
    fun toggleSelectionDot()
    fun shiftPitch(semitones: Int)
    fun shiftOctave(octaves: Int)
    fun setAccidental(raw: String)
    fun toggleAddToChord()
    fun removeSelectedNoteFromChord()
    fun toggleTie()
    fun appendTiedNote()
    fun createTuplet(actualNotes: Int)
    fun removeTuplet()
    fun selectPreviousElement()
    fun selectNextElement()
    fun setActiveVoice(voice: Int)
    fun setPlaybackActive(active: Boolean)
    fun undo()
    fun redo()
}

/**
 * Pure delegation over the generated view model. No policy, no branching — anything else belongs in the relay.
 *
 * Three adaptations here are wire-shape, not policy, so they stay inside "pure delegation":
 * - `revision()` / `appliedIntentCount()` call the bridge's synchronous `revisionNow()` / `appliedIntentCountNow()`
 *   ops rather than reading `.value` off the generated `StateFlow` properties of the same name. That is not a
 *   preference: the generated view model republishes every projection property with
 *   `viewModelScope.launch(Dispatchers.Main) { … }`, and `Dispatchers.Main` always posts to the Looper — it is not
 *   `Dispatchers.Main.immediate`. On the relay's own thread (Compose's main thread) the posted update therefore
 *   cannot run until the relay's op has already returned, so a StateFlow read inside `replay()` yields the value
 *   from *before* the op every time. That is exactly how `undo()` / `redo()` came to be diagnosed as refused and
 *   never relayed to the mirror at all. Every other read on this class was already a direct JNI call; these two
 *   now are as well, and nothing here may go back to the flows.
 * - `encodeScore()` / `takeRelayFrames()` unwrap the generated `EditBytesWire` data class down to the `ByteArray` it
 *   wraps — `EditBytesWire` is wirelet's wire envelope (`emit-wirelet-kotlin`), not a decoded intent, so unwrapping
 *   it inspects nothing.
 * - `setArmedDots` / `setActiveVoice` call the generated `armDots` / `setVoice` — those are just the Swift-side
 *   `EditorBridge` method names, carried across unchanged by wirelet's codegen (`emit-wirelet-observable`). The
 *   generated observable setters for the `armedDots` / `activeVoice` *projection* properties are a different,
 *   already-distinct pair (`updateArmedDots` / `updateActiveVoice`), so there is no name collision **in the
 *   generated Kotlin**. The Swift-side spelling is still forced: jextract derives a native symbol
 *   `Java_..._setArmedDots` from the projection property itself, so an `EditorBridge` op of that name fails the
 *   arm64 link (see `EditorBridge.armDots`'s doc). Do not "restore parity" by renaming the Swift ops — the clash is
 *   invisible from here and only surfaces when cross-compiling. `EditBridging` chose the iOS-shaped op names
 *   (`setArmedDots`, `setActiveVoice`) for parity with the Swift side, and this adapter is where that rename lives
 *   — the whole reason the class exists.
 */
class GeneratedEditBridging(val vm: EditorBridgeViewModel) : EditBridging {
    override fun engineVersionStamp() = vm.engineVersionStamp()
    override fun beginSession(path: String, dir: String, id: String) = vm.beginSession(path, dir, id)
    override fun endSession() = vm.endSession()
    override fun scoreFingerprint() = vm.scoreFingerprint()
    override fun encodeScore(): ByteArray = vm.encodeScore().bytes
    override fun takeRelayFrames(): List<ByteArray> = vm.takeRelayFrames().map { it.bytes }
    override fun revision() = vm.revisionNow()
    override fun appliedIntentCount() = vm.appliedIntentCountNow()

    override fun selectItem(bytes: ByteArray) = vm.selectItem(EditBytesWire(bytes))
    override fun inputPitch(letter: String) = vm.inputPitch(letter)
    override fun deleteSelection() = vm.deleteSelection()
    override fun writeRest() = vm.writeRest()
    override fun armDuration(kind: Int) = vm.armDuration(kind)
    override fun toggleArmedDot() = vm.toggleArmedDot()
    override fun setArmedDots(dots: Int) = vm.armDots(dots)
    override fun setSelectionDuration(kind: Int) = vm.setSelectionDuration(kind)
    override fun setSelectionDots(dots: Int) = vm.setSelectionDots(dots)
    override fun toggleSelectionDot() = vm.toggleSelectionDot()
    override fun shiftPitch(semitones: Int) = vm.shiftPitch(semitones)
    override fun shiftOctave(octaves: Int) = vm.shiftOctave(octaves)
    override fun setAccidental(raw: String) = vm.setAccidental(raw)
    override fun toggleAddToChord() = vm.toggleAddToChord()
    override fun removeSelectedNoteFromChord() = vm.removeSelectedNoteFromChord()
    override fun toggleTie() = vm.toggleTie()
    override fun appendTiedNote() = vm.appendTiedNote()
    override fun createTuplet(actualNotes: Int) = vm.createTuplet(actualNotes)
    override fun removeTuplet() = vm.removeTuplet()
    override fun selectPreviousElement() = vm.selectPreviousElement()
    override fun selectNextElement() = vm.selectNextElement()
    override fun setActiveVoice(voice: Int) = vm.setVoice(voice)
    override fun setPlaybackActive(active: Boolean) = vm.setPlaybackActive(active)
    override fun undo() = vm.undo()
    override fun redo() = vm.redo()
}

/**
 * Why `open()` did or did not leave the session usable.
 *
 * `RESYNC_FAILED` is the open-time counterpart of `resync()`'s own "close rather than leave open" rule (see its
 * doc comment): the fingerprint check `open()` runs before returning found the two copies already diverged, and
 * the resync meant to reconcile them could not complete. `open()` reports that explicitly rather than returning
 * `OPENED` for a session it already had to close — the honest read-only signal SP4 needs to distinguish "editing
 * is unavailable because the two engines disagree and could not be reconciled" from every other refusal.
 */
enum class OpenResult { OPENED, VERSION_SKEW, NO_HANDLE, SCORE_UNREADABLE, MIRROR_REFUSED, RESYNC_FAILED }

/**
 * The single path from a user action to the score.
 *
 * Editing on Android has an authoritative score in Folino's `.so` and a rendering score behind ssm's handle
 * (spec §4). Keeping them identical is four steps that must always happen together and in order — apply locally,
 * relay every intent that landed, check the two agree, redraw — so they are one private method rather than four a
 * caller could get half right, and every editing op is a named entry point that runs it.
 *
 * **The relay owns the bridge.** `bridge` is private, and SP4 gets the ops through this class. A caller holding the
 * view model could apply an intent locally without relaying it: the frames would sit in the queue until the next
 * relayed op drained them — usually harmless, since order is preserved — but a resync in between re-encodes the
 * authoritative score with those edits already in it, and the stranded frames then apply a second time. There is no
 * way to make that safe from the outside, so there is no way in from the outside.
 *
 * ## Threading
 *
 * **Every method here must be called from one thread**, and on Android that thread is Compose's main thread.
 * ssm's side takes a lock across each of its entry points; Folino's bridge deliberately does not (it holds a
 * non-`Sendable` core, one per isolation domain), and an op followed by `takeRelayFrames()` is two separate JNI
 * calls that must not interleave with another op's pair. Do not move these onto a coroutine dispatcher without
 * giving the bridge a lock first.
 *
 * ## Why a `false` is never shrugged off
 *
 * The authoritative side only emits intents it has already applied, so a refusal downstream cannot be a benign
 * no-op: it means no session, corrupted bytes, a released handle, or two images that have already diverged. All four
 * call for a resync (SP0's finding, and the doc comment on `nativeApplyEditIntent` itself).
 */
// PARITY(android): note editing — the session and the relay are here and proven on a physical device, but nothing
//   drives them yet: the contextual app bar, pad, callout and caret overlay are SP4; the save path, autosave, the
//   onPause flush and the sibling-.mscz policy are SP5. Delete this marker when SP5 lands.
class EditSessionRelay(
    private val bridge: EditBridging,
    private val host: EditSessionHost,
    private val natives: EditNatives = RealEditNatives,
) {
    /** Resyncs performed this session. Read by the tests, and by SP4's diagnostics. */
    var resyncCount: Int = 0
        private set

    private var appliedSinceCheck = 0
    private var isOpen = false

    // MARK: - Lifecycle

    /**
     * Opens both sessions, or neither.
     *
     * Three gates, in order.
     *
     * **The version gate (§8.1) is absolute.** Folino's compiled-in `SheetMusicCore` and the one behind the handle
     * must be the same build, because every guarantee here rests on both planning an intent identically. A stale
     * `.so` has bricked this app before, and the answer is to stay read-only rather than to edit and hope. Note what
     * it does *not* catch: the stamp hashes a version string, so a stale mavenLocal AAR rebuilt at the same
     * `0.0.0-SNAPSHOT` sails through. The gate protects shipped skew; keeping the local AARs republished protects
     * dev skew.
     *
     * **Begin/end are strictly paired across both sides.** If the mirror refuses, the authoritative session is
     * closed again before returning — an authoritative session outliving a mirror is how a later undo returns
     * `false` against a score that has already reverted.
     *
     * **The fingerprint check at open is not paranoia; it is the normal second session.** Ending a session does not
     * revert the mirror ("the score keeps whatever the session last wrote" — ssm's own words), and SP3/SP4 ship no
     * save at all. So: edit, close, reopen — and the mirror is seeded from the *edited* score behind the handle
     * while this side parses the *unedited* file. They diverge before the first keystroke, and nothing else would
     * notice for up to `FINGERPRINT_SAMPLE_EVERY` edits — during which taps resolve against one score and edits
     * apply to another, which is the "wrong element edited" failure, not a cosmetic one. Resyncing here pushes the
     * file-parsed score into the handle, which is also the correct semantics: unsaved edits were never persisted, so
     * the file is the truth. The same check covers a failed save, a double open, and a file replaced underneath us.
     */
    fun open(scorePath: String, scoresDirectory: String, scoreId: String): OpenResult {
        if (isOpen) close()
        val handle = host.scoreHandle()
        if (handle == 0L) return OpenResult.NO_HANDLE
        if (bridge.engineVersionStamp() != natives.engineVersionStamp()) return OpenResult.VERSION_SKEW
        if (!bridge.beginSession(scorePath, scoresDirectory, scoreId)) return OpenResult.SCORE_UNREADABLE
        if (!natives.beginEditSession(handle)) {
            bridge.endSession()
            return OpenResult.MIRROR_REFUSED
        }
        appliedSinceCheck = 0
        isOpen = true
        // Unconditional: the case that matters most is exactly the one where verifyOrResync() found the two
        // copies disagreeing and swapped the handle out from under the host — that is when a redraw is needed,
        // not when it can be skipped.
        verifyOrResync()
        host.requestRelayout()
        return if (isOpen) OpenResult.OPENED else OpenResult.RESYNC_FAILED
    }

    /** Ends both sides. Safe to call twice; `nativeEndEditSession` is a no-op for a handle with no session. */
    fun close() {
        if (!isOpen) return
        natives.endEditSession(host.scoreHandle())
        bridge.endSession()
        isOpen = false
    }

    // MARK: - The editing ops
    //
    // One named method per op, each `relay { … }`. They exist so that `bridge` can stay private — see the class
    // doc. Nothing here may branch: a decision in this file is a rule Android has and iOS does not.

    fun selectItem(bytes: ByteArray) = relay { bridge.selectItem(bytes) }
    fun inputPitch(letter: String) = relay { bridge.inputPitch(letter) }
    fun deleteSelection() = relay { bridge.deleteSelection() }
    fun writeRest() = relay { bridge.writeRest() }
    fun armDuration(kind: Int) = relay { bridge.armDuration(kind) }
    fun toggleArmedDot() = relay { bridge.toggleArmedDot() }
    fun setArmedDots(dots: Int) = relay { bridge.setArmedDots(dots) }
    fun setSelectionDuration(kind: Int) = relay { bridge.setSelectionDuration(kind) }
    fun setSelectionDots(dots: Int) = relay { bridge.setSelectionDots(dots) }
    fun toggleSelectionDot() = relay { bridge.toggleSelectionDot() }
    fun shiftPitch(semitones: Int) = relay { bridge.shiftPitch(semitones) }
    fun shiftOctave(octaves: Int) = relay { bridge.shiftOctave(octaves) }
    fun setAccidental(raw: String) = relay { bridge.setAccidental(raw) }
    fun toggleAddToChord() = relay { bridge.toggleAddToChord() }
    fun removeSelectedNoteFromChord() = relay { bridge.removeSelectedNoteFromChord() }
    fun toggleTie() = relay { bridge.toggleTie() }
    fun appendTiedNote() = relay { bridge.appendTiedNote() }
    fun createTuplet(actualNotes: Int) = relay { bridge.createTuplet(actualNotes) }
    fun removeTuplet() = relay { bridge.removeTuplet() }
    fun selectPreviousElement() = relay { bridge.selectPreviousElement() }
    fun selectNextElement() = relay { bridge.selectNextElement() }
    fun setActiveVoice(voice: Int) = relay { bridge.setActiveVoice(voice) }
    fun setPlaybackActive(active: Boolean) = relay { bridge.setPlaybackActive(active) }

    /**
     * Undo and redo drive the mirror's OWN stacks rather than replaying an inverse: it was fed identical intents, so
     * it has an identical stack. They are also always fingerprint-checked, because they are the two operations whose
     * effect on the mirror is inferred rather than transmitted.
     */
    fun undo() = replay(natives::editUndo) { bridge.undo() }

    fun redo() = replay(natives::editRedo) { bridge.redo() }

    // MARK: - The funnel

    /**
     * Performs one op and carries its consequences across.
     *
     * The op may apply no intents (an inert key), one, or several; the frame list is what actually happened, which
     * is why the count comes from the bridge rather than from the op.
     */
    private fun relay(op: () -> Unit) {
        if (!isOpen) return
        op()
        val frames = bridge.takeRelayFrames()
        if (frames.isEmpty()) return
        val handle = host.scoreHandle()
        for (frame in frames) {
            if (!natives.applyEditIntent(handle, frame)) {
                resync()
                host.requestRelayout()
                return
            }
        }
        appliedSinceCheck += frames.size
        if (appliedSinceCheck >= FINGERPRINT_SAMPLE_EVERY) {
            appliedSinceCheck = 0
            verifyOrResync()
        }
        host.requestRelayout()
    }

    private fun replay(mirror: (Long) -> Boolean, local: () -> Unit) {
        if (!isOpen) return
        val before = bridge.appliedIntentCount()
        val revisionBefore = bridge.revision()
        local()
        // A refused undo/redo leaves the local revision where it was, and must not touch the mirror. Both reads are
        // synchronous ops on the bridge (see `GeneratedEditBridging`) — a projection read here would answer with the
        // pre-op value on this thread and make every undo look refused.
        if (bridge.revision() == revisionBefore) return
        // Now a real cross-image invariant rather than a comparison of two equally stale numbers: the counter is
        // read on both sides of `local()` and reflects what the core actually did. It pins the assumption the whole
        // undo design rests on — that an undo mutates the score WITHOUT emitting an intent (`EditorBridge`'s
        // "Undo / redo" note). If one ever did, the frame would still be sitting in the relay queue, and the next
        // resync would re-encode a score that already contains that edit and then apply it a second time. That is a
        // broken contract in `EditorSessionCore`, shared with iOS and covered by its tests — not a runtime
        // condition a user can reach — so it stays a `check`.
        check(bridge.appliedIntentCount() == before) { "undo/redo must not count as an applied intent" }
        if (!mirror(host.scoreHandle())) {
            resync()
        } else {
            appliedSinceCheck = 0
            verifyOrResync()
        }
        host.requestRelayout()
    }

    // MARK: - The §8.3 gate

    /** Returns true when the two copies already agreed; false when they did not and a resync was attempted. */
    private fun verifyOrResync(): Boolean {
        if (bridge.scoreFingerprint() == natives.scoreFingerprint(host.scoreHandle())) return true
        resync()
        return false
    }

    /**
     * Rebuilds the mirror from the authoritative score.
     *
     * Encode → load → swap → reopen the mirror session. The mirror's undo stack is gone afterwards, which is exactly
     * why the authoritative session's stack is the one the UI reads: `canUndo` comes from Folino's side, and a
     * post-resync undo relays into a mirror that will refuse it — which resyncs again, from a score that is by then
     * correct. Divergence costs a redraw and a stack, never a file: saves always encode the authoritative copy.
     *
     * Queued frames are dropped first. The encode about to be loaded already contains every edit they describe, so
     * relaying them afterwards would apply each one twice — the one way a resync could make things worse than the
     * divergence it is repairing.
     *
     * A resync that cannot complete closes the session rather than leaving it open: with the two copies known to
     * disagree and no way to reconcile them, every further op would re-trigger a failing resync, and the taps in
     * between would edit whatever the stale layout resolved to. SP4 surfaces that as dropping back to read-only.
     *
     * **"Cannot complete" includes "completed and still disagrees."** Encode → load → reopen can each answer
     * success and still leave two different scores, because the round trip is only as faithful as the encoder: a
     * gap in ssm's MSCX writer put this very branch in exactly that state for a full device-test cycle. Without the
     * closing comparison below, that state is permanent and nearly silent — every eighth edit resyncs, each resync
     * throws away the mirror's undo stack and swaps the host's handle, and the only trace is a log line. So the
     * fingerprints are compared once more before returning, directly rather than through `verifyOrResync()`, which
     * would call back into here and recurse.
     */
    private fun resync() {
        resyncCount += 1
        Log.w(TAG, "edit session diverged; resyncing the mirror (resync #$resyncCount)")
        bridge.takeRelayFrames()
        val bytes = bridge.encodeScore()
        if (bytes.isEmpty()) {
            Log.e(TAG, "resync failed: the authoritative score would not encode; closing the session")
            close()
            return
        }
        val fresh = natives.loadScore(bytes)
        if (fresh == 0L) {
            Log.e(TAG, "resync failed: the re-encoded score would not load; closing the session")
            close()
            return
        }
        val stale = host.scoreHandle()
        host.replaceScoreHandle(fresh)
        natives.releaseScore(stale)
        if (!natives.beginEditSession(fresh)) {
            Log.e(TAG, "resync failed: the fresh handle would not open a mirror session; closing the session")
            close()
            return
        }
        if (bridge.scoreFingerprint() != natives.scoreFingerprint(fresh)) {
            Log.e(TAG, "resync failed: the two copies still disagree after reloading; closing the session")
            close()
            return
        }
        appliedSinceCheck = 0
    }

    companion object {
        private const val TAG = "EditSessionRelay"

        /**
         * How many applied intents may pass between fingerprint checks.
         *
         * `stableFingerprint` walks the whole value tree, so it is the one thing here whose cost grows with the
         * score. Task 9's device test (`EditSessionParityTest.fingerprintWalkIsCheapEnoughToSample`) measured one
         * walk on `parity.mscz` — a real 127-measure, 6-part arrangement — on a physical Pixel 8a at **~1.9ms**
         * (1908us and 1911us across two runs), under the ~2ms line this comment used to guess at. At
         * `FINGERPRINT_SAMPLE_EVERY = 8` that amortizes to ~239us per applied intent, comfortably under the
         * half-millisecond budget, so eight stays unchanged. Raise it (recomputing the amortized cost against a
         * fresh measurement) only if a future score/device combination pushes the walk itself past ~4ms. Session
         * open, undo, redo and (from SP5) every save check unconditionally regardless of this number.
         */
        const val FINGERPRINT_SAMPLE_EVERY = 8
    }
}
