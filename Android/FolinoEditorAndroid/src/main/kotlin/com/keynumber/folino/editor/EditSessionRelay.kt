package com.keynumber.folino.editor

import android.util.Log
import com.keynumber.folino.editor.generated.EditorBridgeViewModel
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.serialization.NoteIDCodec

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

    /** Writes the session's pending edits, if any. A no-op when nothing changed since the last save. */
    fun flushSave()
    fun scoreFingerprint(): Long
    fun encodeScore(): ByteArray
    fun takeRelayFrames(): List<ByteArray>

    /**
     * The note the last op asked to have previewed, as a `NoteID` wire — empty when it asked for none. Synchronous
     * for the same reason [revision] and [appliedIntentCount] are; see `EditorBridge.takePendingAudition`.
     */
    fun takePendingAudition(): ByteArray
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
    fun discardSessionEdits()
    fun revertToOriginal(): Boolean
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
class GeneratedEditBridging(private val vm: EditorBridgeViewModel) : EditBridging, EditProjection {
    override fun engineVersionStamp() = vm.engineVersionStamp()
    override fun beginSession(path: String, dir: String, id: String) = vm.beginSession(path, dir, id)
    override fun endSession() = vm.endSession()
    override fun flushSave() = vm.flushSave()
    override fun scoreFingerprint() = vm.scoreFingerprint()
    override fun encodeScore(): ByteArray = vm.encodeScore().bytes
    override fun takeRelayFrames(): List<ByteArray> = vm.takeRelayFrames().map { it.bytes }
    override fun takePendingAudition(): ByteArray = vm.takePendingAudition().bytes
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
    override fun discardSessionEdits() = vm.discardSessionEdits()
    override fun revertToOriginal() = vm.revertToOriginal()
    override fun undo() = vm.undo()
    override fun redo() = vm.redo()

    // EditProjection — everything Compose reads, and nothing it can write. See that interface's doc comment.
    override val isSessionActive get() = vm.isSessionActive
    override val revision get() = vm.revision
    override val selectionRevision get() = vm.selectionRevision
    override val canUndo get() = vm.canUndo
    override val canRedo get() = vm.canRedo
    override val hasEditTarget get() = vm.hasEditTarget
    override val isNoteSelected get() = vm.isNoteSelected
    override val hasSelectionCallout get() = vm.hasSelectionCallout
    override val canWriteRest get() = vm.canWriteRest
    override val canTie get() = vm.canTie
    override val isSelectionTied get() = vm.isSelectionTied
    override val canAppendTiedNote get() = vm.canAppendTiedNote
    override val isCaretInTuplet get() = vm.isCaretInTuplet
    override val armedDurationKind get() = vm.armedDurationKind
    override val armedDots get() = vm.armedDots
    override val isAddToChordArmed get() = vm.isAddToChordArmed
    override val armedTuplet get() = vm.armedTuplet
    override val calloutDurationKind get() = vm.calloutDurationKind
    override val calloutDots get() = vm.calloutDots
    override val activeVoice get() = vm.activeVoice
    override val sessionHasEdits get() = vm.sessionHasEdits
    override val canRevertToOriginal get() = vm.canRevertToOriginal
    override val didSaveAsSiblingMSCZ get() = vm.didSaveAsSiblingMSCZ
    override val sessionEndModeKind get() = vm.sessionEndModeKind
    override val selectedItemFrame get() = vm.selectedItemFrame
    override val caretItemFrame get() = vm.caretItemFrame
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
 * Sounds the one-shot pitch preview the shared core asked for. Android's counterpart of iOS's `NoteAuditioning`.
 *
 * A seam rather than a direct call for the same reason iOS has one: the DECISION — which note, and after which ops
 * — belongs to `EditorSessionCore` and is already made by the time this is called; all that is left is an audio
 * engine, which `:FolinoEditorAndroid` neither owns nor should reach for. The composition root wires this to
 * `ReaderAudioViewModel.playNotePreview`, and a relay built without one simply stays silent.
 */
fun interface NoteAuditioning {
    fun playPreview(noteId: NoteID)
}

/**
 * The relay's own surface, behind an interface for the same reason `EditBridging` and `EditNatives` are:
 * `EditSessionRelay` is a final class, so SP4's `EditSessionController` — the piece actually worth being sure
 * about, since it is what maps a five-case `OpenResult` down to what the UI shows — would otherwise be testable
 * only on a device. `EditSessionRelay` is a pure implementation of this interface; nothing here may branch on its
 * behalf, and `EditSessionController` is written against this interface, never against the concrete class.
 *
 * Every member mirrors a method `EditSessionRelay` already exposes — `open`/`close` plus one entry per editing op —
 * so add one here whenever the relay grows a new op the controller needs to reach.
 */
interface EditSessionOps {
    fun open(scorePath: String, scoresDirectory: String, scoreId: String): OpenResult
    fun close()

    /** Writes any pending edit now, without ending the session. Driven from the Reader's `onPause`. */
    fun flushPendingSave()

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
    fun discardSessionEdits()
    fun revertToOriginal(): Boolean
    fun undo()
    fun redo()
}

/**
 * The single path from a user action to the score.
 *
 * Editing on Android has an authoritative score in Folino's `.so` and a rendering score behind ssm's handle
 * (spec §4). Keeping them identical is four steps that must always happen together and in order — apply locally,
 * relay every intent that landed, check the two agree, redraw — so they are one private method rather than four a
 * caller could get half right, and every editing op is a named entry point that runs it. A fifth step rides along
 * at the end: sounding the preview the shared core asked for, which has to come last because it reads the mirror.
 *
 * **The relay owns the bridge.** `bridge` is private, and SP4 gets the ops through this class. A caller holding the
 * view model could apply an intent locally without relaying it: the frames would sit in the queue until the next
 * relayed op drained them — usually harmless, since order is preserved — but a resync in between re-encodes the
 * authoritative score with those edits already in it, and the stranded frames then apply a second time. There is no
 * way to make that safe from the outside, so there is no way in from the outside.
 *
 * ## Threading
 *
 * **Every method here must be called from one thread**, and in the app that thread is a dedicated single-thread
 * executor rather than Compose's main thread — see [ConfinedEditSessionOps] for what put it there and why (a save
 * encodes the whole score, ~200 ms on a Pixel 8a, and none of that may land on the thread that draws).
 * ssm's side takes a lock across each of its entry points; Folino's bridge deliberately does not (it holds a
 * non-`Sendable` core, one per isolation domain), and an op followed by `takeRelayFrames()` is two separate JNI
 * calls that must not interleave with another op's pair. Do not move these onto a general coroutine dispatcher
 * without giving the bridge a lock first — a SINGLE-thread executor is what satisfies that condition here, by
 * construction rather than by a lock.
 *
 * The instrumented suites drive this class from Android's main thread instead, which is equally valid: the contract
 * asks for one thread, not for a particular one.
 *
 * ## Why a `false` is never shrugged off
 *
 * The authoritative side only emits intents it has already applied, so a refusal downstream cannot be a benign
 * no-op: it means no session, corrupted bytes, a released handle, or two images that have already diverged. All four
 * call for a resync (SP0's finding, and the doc comment on `nativeApplyEditIntent` itself).
 */
class EditSessionRelay(
    private val bridge: EditBridging,
    private val host: EditSessionHost,
    private val natives: EditNatives = RealEditNatives,
    private val audition: NoteAuditioning = NoteAuditioning {},
    private val autosave: EditAutosave,
) : EditSessionOps {
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
     * revert the mirror ("the score keeps whatever the session last wrote" — ssm's own words). With SP5 the two
     * usually agree at reopen, because this side now parses a file that HOLDS the edits — which is exactly why the
     * check has to stay: the cases where they do not agree are a save that failed (§8.4 leaves the session dirty and
     * the file behind), a discard whose write-back did not land, a double open, and a file replaced underneath us.
     * In any of those the mirror is seeded from one score while this side parses another, and nothing else would
     * notice for up to `FINGERPRINT_SAMPLE_EVERY` edits — during which taps resolve against one score and edits
     * apply to another, which is the "wrong element edited" failure, not a cosmetic one. Resyncing here pushes the
     * file-parsed score into the handle, which is also the correct semantics: what the mirror holds beyond the file
     * was never persisted, so the file is the truth.
     */
    override fun open(scorePath: String, scoresDirectory: String, scoreId: String): OpenResult {
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
    override fun close() {
        if (!isOpen) return
        // Before anything is torn down: the debounce may be holding an unwritten edit, and `endSession` drops the
        // authoritative session that owns it. iOS flushes in `EditorViewModel.endSession` for the same reason.
        autosave.flushNow()
        natives.endEditSession(host.scoreHandle())
        bridge.endSession()
        isOpen = false
    }

    /**
     * Writes any pending edit now, without ending the session. The Activity calls this on `onPause` — the last moment
     * Android guarantees before a process can be killed, and where the annotation save is flushed too.
     */
    override fun flushPendingSave() {
        if (!isOpen) return
        autosave.flushNow()
    }

    // MARK: - The editing ops
    //
    // One named method per op, each `relay { … }`. They exist so that `bridge` can stay private — see the class
    // doc. Nothing here may branch: a decision in this file is a rule Android has and iOS does not.

    override fun selectItem(bytes: ByteArray) = relay { bridge.selectItem(bytes) }
    override fun inputPitch(letter: String) = relay { bridge.inputPitch(letter) }
    override fun deleteSelection() = relay { bridge.deleteSelection() }
    override fun writeRest() = relay { bridge.writeRest() }
    override fun armDuration(kind: Int) = relay { bridge.armDuration(kind) }
    override fun toggleArmedDot() = relay { bridge.toggleArmedDot() }
    override fun setArmedDots(dots: Int) = relay { bridge.setArmedDots(dots) }
    override fun setSelectionDuration(kind: Int) = relay { bridge.setSelectionDuration(kind) }
    override fun setSelectionDots(dots: Int) = relay { bridge.setSelectionDots(dots) }
    override fun toggleSelectionDot() = relay { bridge.toggleSelectionDot() }
    override fun shiftPitch(semitones: Int) = relay { bridge.shiftPitch(semitones) }
    override fun shiftOctave(octaves: Int) = relay { bridge.shiftOctave(octaves) }
    override fun setAccidental(raw: String) = relay { bridge.setAccidental(raw) }
    override fun toggleAddToChord() = relay { bridge.toggleAddToChord() }
    override fun removeSelectedNoteFromChord() = relay { bridge.removeSelectedNoteFromChord() }
    override fun toggleTie() = relay { bridge.toggleTie() }
    override fun appendTiedNote() = relay { bridge.appendTiedNote() }
    override fun createTuplet(actualNotes: Int) = relay { bridge.createTuplet(actualNotes) }
    override fun removeTuplet() = relay { bridge.removeTuplet() }
    override fun selectPreviousElement() = relay { bridge.selectPreviousElement() }
    override fun selectNextElement() = relay { bridge.selectNextElement() }
    override fun setActiveVoice(voice: Int) = relay { bridge.setActiveVoice(voice) }
    override fun setPlaybackActive(active: Boolean) = relay { bridge.setPlaybackActive(active) }

    /**
     * Throws this session's edits away.
     *
     * Not a `relay { }` op: the unwind drives `ScoreEditSession` directly rather than through `apply`, so — like
     * undo — it emits no intent frames, and unlike undo there is no single native call that reproduces it on the
     * mirror (it is N undos, and sometimes a rebuild from the opening score). So the two copies are reconciled the
     * one way that always works regardless of how far apart they drifted: compare fingerprints and resync.
     *
     * That makes a discard the most expensive op here, which is the right trade — it happens once, deliberately,
     * and correctness after it matters more than its cost.
     */
    override fun discardSessionEdits() {
        if (!isOpen) return
        // The armed write is for the score the user has just decided to throw away. Cancel rather than flush; the
        // write-back of the UNWOUND score is `EditorBridge.discardSessionEdits`'s own, on the Swift side.
        autosave.cancel()
        bridge.discardSessionEdits()
        // Whatever the unwind left behind must not ride along into the mirror as if it were a fresh edit.
        bridge.takeRelayFrames()
        bridge.takePendingAudition()
        verifyOrResync()
        host.requestRelayout()
    }

    /**
     * Restores the file from the copy taken at import. Always `false` today — see `EditorBridge.revertToOriginal`,
     * which is where the parity marker for the missing Android half lives.
     */
    override fun revertToOriginal(): Boolean {
        if (!isOpen) return false
        return bridge.revertToOriginal()
    }

    /**
     * Undo and redo drive the mirror's OWN stacks rather than replaying an inverse: it was fed identical intents, so
     * it has an identical stack. They are also always fingerprint-checked, because they are the two operations whose
     * effect on the mirror is inferred rather than transmitted.
     */
    override fun undo() = replay(natives::editUndo) { bridge.undo() }

    override fun redo() = replay(natives::editRedo) { bridge.redo() }

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
        // Unconditional, from the one place no op can skip. iOS arms in its own op funnel for the reason
        // `EditorViewModel+Ops`'s doc gives — "the autosave timer can never be skipped for one op and not another" —
        // and an op that changed nothing costs only a timer tick that `performSave` then answers with "not dirty".
        // NOT in `carryToMirror()`: that returns early when the op applied no frames, and undo/redo move the score
        // without emitting any, so arming there would miss exactly the ops that matter most.
        autosave.arm()
        // Drained here, before the frames, because `takePendingAudition` empties the core: [carryToMirror] returns
        // early on an op that applied nothing — a tap, above all — and a request left behind would be picked up by
        // whichever op ran next and sound the wrong note.
        val auditionFrame = bridge.takePendingAudition()
        carryToMirror()
        sound(auditionFrame)
    }

    /** Relays whatever the op applied. Split out of [relay] only so its early returns stay early returns. */
    private fun carryToMirror() {
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

    /**
     * Sounds a drained audition request — **after** the op's intents have reached the mirror, never before.
     *
     * The engine resolves a `NoteID` to a pitch against the score behind the handle (`pitchAndStaffOfNote`), which
     * is the MIRROR, not the authoritative copy this bridge edits. A note that was just written does not exist
     * there until `applyEditIntent` has carried it across, so previewing first would silently find nothing and
     * return — which is a preview that works for retuning an existing note and not for writing a new one, the
     * hardest kind of gap to notice.
     *
     * A session that a failed resync has just closed sounds nothing: its handle has been swapped and the mirror is
     * no longer known to match.
     */
    private fun sound(auditionFrame: ByteArray) {
        if (!isOpen || auditionFrame.isEmpty()) return
        val noteId = try {
            NoteIDCodec.decode(auditionFrame)
        } catch (e: Exception) {
            Log.w(TAG, "could not decode the pending audition; skipping the preview", e)
            return
        }
        audition.playPreview(noteId)
    }

    private fun replay(mirror: (Long) -> Boolean, local: () -> Unit) {
        if (!isOpen) return
        val before = bridge.appliedIntentCount()
        val revisionBefore = bridge.revision()
        local()
        // The funnel's other half — see `relay`. An undo the core refused leaves the session clean, so arming for it
        // costs one tick that `performSave` answers with "not dirty"; an undo it accepted has to be written.
        autosave.arm()
        // A refused undo/redo leaves the local revision where it was, and must not touch the mirror. Both reads are
        // synchronous ops on the bridge (see `GeneratedEditBridging`) — a projection read here would answer with the
        // pre-op value on this thread and make every undo look refused.
        if (bridge.revision() == revisionBefore) return
        // An undo must move the score WITHOUT emitting an intent (`EditorBridge`'s "Undo / redo" note). If one
        // ever did, the frame would sit in the queue and the next resync — which re-encodes an authoritative score
        // that already contains that edit — would apply it a second time. Answer it the way every other
        // cross-image disagreement in this file is answered: drop what is stranded and rebuild the mirror. A
        // `check` here would instead crash the app in release, over an invariant the user cannot influence.
        val stranded = bridge.takeRelayFrames()
        if (stranded.isNotEmpty()) {
            Log.w(TAG, "undo/redo emitted ${stranded.size} intent frame(s); resyncing rather than replaying them")
            resync()
            host.requestRelayout()
            return
        }
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
     * **The superseded handle is handed to the host, not freed here.** `EditSessionHost.replaceScoreHandle`'s own doc
     * carries the reasoning: on Android the score behind that handle has also been given to the audio engine and to a
     * bound service that outlives the Reader, so no host can prove it has stopped being read at this instant, and a
     * `nativeReleaseScore` on this line would be a use-after-free rather than a tidy-up. Ownership therefore sits
     * entirely with the host — including the freeing, which it does once it can show no holder is left, rather than
     * keeping the handle for the process. Nothing about that is this file's business beyond not pre-empting it: a
     * release here would be doing it at the one moment it is provably unsafe.
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
        host.replaceScoreHandle(fresh)
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
